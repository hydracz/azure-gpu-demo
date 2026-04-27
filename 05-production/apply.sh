#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST_DIR="${SCRIPT_DIR}/manifests"
RENDERED_DIR="${SCRIPT_DIR}/.rendered"
DEFAULT_ENV_FILE="${SCRIPT_DIR}/production.env"

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "missing required command: $1"
}

wait_for_hpa() {
  local scaledobject_name="$1"
  local namespace="$2"
  local attempts="${3:-30}"
  local attempt

  for attempt in $(seq 1 "${attempts}"); do
    if kubectl get hpa -n "${namespace}" --no-headers 2>/dev/null | grep -q "${scaledobject_name}"; then
      return 0
    fi

    if [[ "${attempt}" == "${attempts}" ]]; then
      fail "Timed out waiting for KEDA-generated HPA for ${scaledobject_name}"
    fi

    sleep 5
  done
}

need_cmd kubectl
need_cmd envsubst

ENV_FILE="${PRODUCTION_ENV_FILE:-${DEFAULT_ENV_FILE}}"

[[ -f "${ENV_FILE}" ]] || fail "missing env file: ${ENV_FILE}"

set -a
# shellcheck disable=SC1090
source "${ENV_FILE}"
set +a

[[ -n "${IMAGE_URL:-}" ]] || fail "IMAGE_URL is required"
[[ -n "${MONITOR_WORKSPACE_QUERY_ENDPOINT:-}" ]] || fail "MONITOR_WORKSPACE_QUERY_ENDPOINT is required"

APP_NAME="${APP_NAME:-${appname:-production-app}}"

[[ "${APP_NAME}" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || fail "APP_NAME must be a Kubernetes DNS label, got: ${APP_NAME}"
(( ${#APP_NAME} <= 48 )) || fail "APP_NAME must be 48 characters or fewer so generated resource names stay valid"

export APP_NAME
export IMAGE_URL
export CONTAINER_COMMAND="${CONTAINER_COMMAND:-sleep 10000}"
export MONITOR_WORKSPACE_QUERY_ENDPOINT

rm -rf "${RENDERED_DIR}"
mkdir -p "${RENDERED_DIR}"

for manifest in "${MANIFEST_DIR}"/*.yaml; do
  rendered_manifest="${RENDERED_DIR}/$(basename "${manifest}")"
  envsubst '${APP_NAME} ${IMAGE_URL} ${CONTAINER_COMMAND} ${MONITOR_WORKSPACE_QUERY_ENDPOINT}' < "${manifest}" > "${rendered_manifest}"
  log "Applying ${rendered_manifest}"
  kubectl apply -f "${rendered_manifest}"
done

log "Waiting for Gateway ${APP_NAME}/${APP_NAME}-internal to be programmed"
kubectl wait \
  --for=condition=programmed \
  --timeout=20m \
  -n "${APP_NAME}" \
  "gateway.gateway.networking.k8s.io/${APP_NAME}-internal"

log "Waiting for seed deployment rollout"
kubectl rollout status "deployment/${APP_NAME}-seed" -n "${APP_NAME}" --timeout=30m

wait_for_hpa "${APP_NAME}-elastic" "${APP_NAME}"
wait_for_hpa "${APP_NAME}-seed" "${APP_NAME}"

log "Production deployment applied"
log "  env file        : ${ENV_FILE}"
log "  app name        : ${APP_NAME}"
log "  namespace       : ${APP_NAME}"
log "  image           : ${IMAGE_URL}"
log "  command         : ${CONTAINER_COMMAND}"
log "  prometheus      : ${MONITOR_WORKSPACE_QUERY_ENDPOINT}"
log "  host            : ${APP_NAME}.internal"
log "  rendered yaml   : ${RENDERED_DIR}"
