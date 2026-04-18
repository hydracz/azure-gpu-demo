#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../../common.sh"

load_env
need_cmd kubectl

require_env AZ_SUBSCRIPTION_ID RESOURCE_GROUP CLUSTER_NAME

ensure_aks_kubeconfig

QWEN_LOADTEST_NAMESPACE="${QWEN_LOADTEST_NAMESPACE:-qwen-loadtest}"
QWEN_LOADTEST_NAME="${QWEN_LOADTEST_NAME:-qwen-loadtest-target}"
QWEN_LOADTEST_SERVICE_NAME="${QWEN_LOADTEST_SERVICE_NAME:-${QWEN_LOADTEST_NAME}}"
QWEN_LOADTEST_CERTIFICATE_NAME="${QWEN_LOADTEST_CERTIFICATE_NAME:-${QWEN_LOADTEST_TLS_SECRET_NAME:-qwen-loadtest-target-tls}}"
QWEN_LOADTEST_GATEWAY_NAME="${QWEN_LOADTEST_GATEWAY_NAME:-qwen-loadtest-internal}"
QWEN_LOADTEST_TLS_SECRET_NAME="${QWEN_LOADTEST_TLS_SECRET_NAME:-qwen-loadtest-target-tls}"
QWEN_LOADTEST_GATEWAY_WORKLOAD_NAMESPACE="${QWEN_LOADTEST_GATEWAY_WORKLOAD_NAMESPACE:-${QWEN_LOADTEST_NAMESPACE}}"
QWEN_LOADTEST_GATEWAY_SELECTOR="${QWEN_LOADTEST_GATEWAY_SELECTOR:-${QWEN_LOADTEST_GATEWAY_NAME}}"
QWEN_LOADTEST_IMAGE_PULL_SECRET_NAME="${QWEN_LOADTEST_IMAGE_PULL_SECRET_NAME:-qwen-loadtest-source-regcred}"
QWEN_LOADTEST_SEED_NAME="${QWEN_LOADTEST_SEED_NAME:-${QWEN_LOADTEST_NAME}-seed}"
QWEN_LOADTEST_ELASTIC_NAME="${QWEN_LOADTEST_ELASTIC_NAME:-${QWEN_LOADTEST_NAME}-elastic}"
QWEN_LOADTEST_SEED_SCALEDOBJECT_NAME="${QWEN_LOADTEST_SEED_SCALEDOBJECT_NAME:-${QWEN_LOADTEST_SEED_NAME}}"
QWEN_LOADTEST_ELASTIC_SCALEDOBJECT_NAME="${QWEN_LOADTEST_ELASTIC_SCALEDOBJECT_NAME:-${QWEN_LOADTEST_ELASTIC_NAME}}"
QWEN_LOADTEST_DELETE_WAIT_SECONDS="${QWEN_LOADTEST_DELETE_WAIT_SECONDS:-600}"

clear_generated_env_keys() {
  [[ -f "${GENERATED_ENV_FILE}" ]] || return 0

  python3 - "${GENERATED_ENV_FILE}" "$@" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
keys = set(sys.argv[2:])
lines = path.read_text(encoding='utf-8').splitlines()
filtered = []

for line in lines:
    key = line.split('=', 1)[0]
    if key in keys:
        continue
    filtered.append(line)

path.write_text("\n".join(filtered) + ("\n" if filtered else ""), encoding='utf-8')
PY
}

wait_for_qwen_resource_deleted() {
  local resource_kind="$1"
  local resource_name="$2"
  local resource_namespace="$3"
  local attempts="$4"
  local attempt

  for attempt in $(seq 1 "${attempts}"); do
    if ! kubectl get "${resource_kind}" "${resource_name}" -n "${resource_namespace}" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done

  warn "Timed out waiting for ${resource_kind}/${resource_name} in namespace ${resource_namespace} to be deleted"
  return 1
}

if ! kubectl get namespace "${QWEN_LOADTEST_NAMESPACE}" >/dev/null 2>&1; then
  log "Namespace ${QWEN_LOADTEST_NAMESPACE} does not exist, nothing to delete"
else
  kubectl delete scaledobject.keda.sh "${QWEN_LOADTEST_SEED_SCALEDOBJECT_NAME}" -n "${QWEN_LOADTEST_NAMESPACE}" --ignore-not-found >/dev/null 2>&1 || true
  kubectl delete scaledobject.keda.sh "${QWEN_LOADTEST_ELASTIC_SCALEDOBJECT_NAME}" -n "${QWEN_LOADTEST_NAMESPACE}" --ignore-not-found >/dev/null 2>&1 || true
  kubectl delete destinationrule.networking.istio.io "${QWEN_LOADTEST_NAME}" -n "${QWEN_LOADTEST_NAMESPACE}" --ignore-not-found >/dev/null 2>&1 || true
  kubectl delete httproute.gateway.networking.k8s.io "${QWEN_LOADTEST_NAME}" -n "${QWEN_LOADTEST_NAMESPACE}" --ignore-not-found >/dev/null 2>&1 || true
  kubectl delete gateway.gateway.networking.k8s.io "${QWEN_LOADTEST_GATEWAY_NAME}" -n "${QWEN_LOADTEST_GATEWAY_WORKLOAD_NAMESPACE}" --ignore-not-found >/dev/null 2>&1 || true
  kubectl delete service "${QWEN_LOADTEST_SERVICE_NAME}" -n "${QWEN_LOADTEST_NAMESPACE}" --ignore-not-found >/dev/null 2>&1 || true
  kubectl delete deployment "${QWEN_LOADTEST_SEED_NAME}" -n "${QWEN_LOADTEST_NAMESPACE}" --ignore-not-found >/dev/null 2>&1 || true
  kubectl delete deployment "${QWEN_LOADTEST_ELASTIC_NAME}" -n "${QWEN_LOADTEST_NAMESPACE}" --ignore-not-found >/dev/null 2>&1 || true
  kubectl delete secret "${QWEN_LOADTEST_IMAGE_PULL_SECRET_NAME}" -n "${QWEN_LOADTEST_NAMESPACE}" --ignore-not-found >/dev/null 2>&1 || true

  wait_attempts="$(( QWEN_LOADTEST_DELETE_WAIT_SECONDS > 0 ? QWEN_LOADTEST_DELETE_WAIT_SECONDS : 1 ))"
  wait_for_qwen_resource_deleted deployment "${QWEN_LOADTEST_SEED_NAME}" "${QWEN_LOADTEST_NAMESPACE}" "${wait_attempts}" || true
  wait_for_qwen_resource_deleted deployment "${QWEN_LOADTEST_ELASTIC_NAME}" "${QWEN_LOADTEST_NAMESPACE}" "${wait_attempts}" || true
  wait_for_qwen_resource_deleted service "${QWEN_LOADTEST_SERVICE_NAME}" "${QWEN_LOADTEST_NAMESPACE}" "${wait_attempts}" || true
  wait_for_qwen_resource_deleted gateway "${QWEN_LOADTEST_GATEWAY_NAME}" "${QWEN_LOADTEST_GATEWAY_WORKLOAD_NAMESPACE}" "${wait_attempts}" || true

  for attempt in $(seq 1 "${wait_attempts}"); do
    if [[ "$(kubectl get pods -n "${QWEN_LOADTEST_NAMESPACE}" -l "app=${QWEN_LOADTEST_NAME}" --no-headers 2>/dev/null | wc -l | tr -d ' ')" == "0" ]]; then
      break
    fi
    sleep 1
  done

  if [[ "${DELETE_QWEN_LOADTEST_NAMESPACE:-false}" == "true" ]]; then
    kubectl delete namespace "${QWEN_LOADTEST_NAMESPACE}" --ignore-not-found >/dev/null 2>&1 || true
    wait_for_namespace_deleted "${QWEN_LOADTEST_NAMESPACE}" 300 || true
  else
    kubectl label namespace "${QWEN_LOADTEST_NAMESPACE}" istio.io/rev- >/dev/null 2>&1 || true
    kubectl -n "${QWEN_LOADTEST_NAMESPACE}" get all --ignore-not-found || true
  fi
fi

if [[ "${DELETE_QWEN_LOADTEST_TLS_SECRET:-true}" == "true" ]]; then
  kubectl delete certificate.cert-manager.io "${QWEN_LOADTEST_CERTIFICATE_NAME}" -n "${QWEN_LOADTEST_GATEWAY_WORKLOAD_NAMESPACE}" --ignore-not-found >/dev/null 2>&1 || true
  kubectl delete secret "${QWEN_LOADTEST_TLS_SECRET_NAME}" -n "${QWEN_LOADTEST_GATEWAY_WORKLOAD_NAMESPACE}" --ignore-not-found >/dev/null 2>&1 || true
fi

clear_generated_env_keys \
  QWEN_LOADTEST_CERTIFICATE_NAME \
  QWEN_LOADTEST_ELASTIC_KEDA_QUERY \
  QWEN_LOADTEST_ELASTIC_MAX_REPLICAS \
  QWEN_LOADTEST_ELASTIC_MIN_REPLICAS \
  QWEN_LOADTEST_ELASTIC_NAME \
  QWEN_LOADTEST_ELASTIC_SCALEDOBJECT_NAME \
  QWEN_LOADTEST_GATEWAY_INTERNAL_LB \
  QWEN_LOADTEST_GATEWAY_IP \
  QWEN_LOADTEST_GATEWAY_SCHEME \
  QWEN_LOADTEST_GATEWAY_SELECTOR \
  QWEN_LOADTEST_GATEWAY_WORKLOAD_NAMESPACE \
  QWEN_LOADTEST_HOST \
  QWEN_LOADTEST_IMAGE_PULL_SECRET_NAME \
  QWEN_LOADTEST_ISTIO_REVISION \
  QWEN_LOADTEST_KEDA_AUTH_NAME \
  QWEN_LOADTEST_KEDA_QUERY \
  QWEN_LOADTEST_NAME \
  QWEN_LOADTEST_NAMESPACE \
  QWEN_LOADTEST_SEED_KEDA_QUERY \
  QWEN_LOADTEST_SEED_MAX_REPLICAS \
  QWEN_LOADTEST_SEED_MIN_REPLICAS \
  QWEN_LOADTEST_SEED_NAME \
  QWEN_LOADTEST_SEED_QUERY_OFFSET \
  QWEN_LOADTEST_SEED_SCALEDOBJECT_NAME \
  QWEN_LOADTEST_SERVICE_NAME \
  QWEN_LOADTEST_TEST_MODE \
  QWEN_LOADTEST_TEST_PATH \
  QWEN_LOADTEST_TEST_VIA_CLUSTER_GATEWAY \
  QWEN_LOADTEST_TLS_ENABLED \
  QWEN_LOADTEST_TLS_SECRET_NAME \
  QWEN_LOADTEST_URL

log "Qwen loadtest resources removed"