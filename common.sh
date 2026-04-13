#!/usr/bin/env bash

set -euo pipefail

COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="${COMMON_DIR}"
ENV_FILE="${AKS_ENV_FILE:-${ROOT_DIR}/aks.env}"
GENERATED_ENV_FILE="${ROOT_DIR}/.generated.env"
DEFAULT_AKS_KUBECONFIG_FILE="${ROOT_DIR}/01-environment/terraform/.generated-kubeconfig"

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

warn() {
  printf '[%s] WARNING: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2
}

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "missing required command: $1"
}

ensure_parent_dir() {
  local target_path="$1"
  local target_dir

  target_dir="$(dirname "${target_path}")"
  mkdir -p "${target_dir}"
}

load_env() {
  if [[ ! -f "${ENV_FILE}" ]]; then
    fail "missing env file: ${ENV_FILE}. Copy aks.env.sample to aks.env first, or set AKS_ENV_FILE to an existing env file."
  fi

  set -a
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
  if [[ -f "${GENERATED_ENV_FILE}" ]]; then
    # shellcheck disable=SC1090
    source "${GENERATED_ENV_FILE}"
  fi
  set +a
}

require_env() {
  local name
  for name in "$@"; do
    [[ -n "${!name:-}" ]] || fail "required env var is empty: ${name}"
  done
}

ensure_tooling() {
  need_cmd az
  need_cmd kubectl
  need_cmd python3
  need_cmd docker
  need_cmd helm
}

aks_exists() {
  az aks show \
    --resource-group "${RESOURCE_GROUP}" \
    --name "${CLUSTER_NAME}" \
    --only-show-errors \
    >/dev/null 2>&1
}

nodepool_exists() {
  local pool_name="$1"
  az aks nodepool show \
    --resource-group "${RESOURCE_GROUP}" \
    --cluster-name "${CLUSTER_NAME}" \
    --name "${pool_name}" \
    --only-show-errors \
    >/dev/null 2>&1
}

resource_group_exists() {
  az group exists \
    --name "${RESOURCE_GROUP}" \
    --only-show-errors
}

wait_for_namespace_deleted() {
  local namespace="$1"
  local timeout_seconds="${2:-900}"
  local poll_interval=10
  local elapsed=0

  log "Waiting for namespace ${namespace} to be deleted"

  while (( elapsed < timeout_seconds )); do
    if ! kubectl get namespace "${namespace}" >/dev/null 2>&1; then
      return 0
    fi
    sleep "${poll_interval}"
    elapsed=$((elapsed + poll_interval))
  done

  warn "Timed out waiting for namespace ${namespace} to be deleted"
  return 1
}

wait_for_resource_group_deleted() {
  local timeout_seconds="${1:-3600}"
  local poll_interval=20
  local elapsed=0
  local exists="true"

  log "Waiting for resource group ${RESOURCE_GROUP} to be deleted"

  while (( elapsed < timeout_seconds )); do
    exists="$(resource_group_exists 2>/dev/null || echo true)"
    if [[ "${exists}" == "false" ]]; then
      return 0
    fi
    sleep "${poll_interval}"
    elapsed=$((elapsed + poll_interval))
  done

  warn "Timed out waiting for resource group ${RESOURCE_GROUP} to be deleted"
  return 1
}

wait_for_aks_ready() {
  local timeout_seconds="${1:-1800}"
  local poll_interval=20
  local elapsed=0
  local state=""

  log "Waiting for AKS cluster ${CLUSTER_NAME} to reach provisioningState=Succeeded"

  while (( elapsed < timeout_seconds )); do
    state="$(az aks show \
      --resource-group "${RESOURCE_GROUP}" \
      --name "${CLUSTER_NAME}" \
      --query provisioningState \
      -o tsv \
      --only-show-errors 2>/dev/null || true)"

    case "${state}" in
      Succeeded)
        return 0
        ;;
      Failed|Canceled)
        fail "AKS cluster ${CLUSTER_NAME} entered provisioningState=${state}"
        ;;
    esac

    sleep "${poll_interval}"
    elapsed=$((elapsed + poll_interval))
  done

  fail "Timed out waiting for AKS cluster ${CLUSTER_NAME} to become ready; last provisioningState=${state:-unknown}"
}

resolve_aks_kubeconfig_file() {
  printf '%s\n' "${AKS_KUBECONFIG_FILE:-${DEFAULT_AKS_KUBECONFIG_FILE}}"
}

ensure_aks_kubeconfig() {
  local kubeconfig_file

  need_cmd az
  need_cmd kubectl
  require_env AZ_SUBSCRIPTION_ID RESOURCE_GROUP CLUSTER_NAME

  kubeconfig_file="${1:-$(resolve_aks_kubeconfig_file)}"
  ensure_parent_dir "${kubeconfig_file}"

  az account set --subscription "${AZ_SUBSCRIPTION_ID}" --only-show-errors >/dev/null
  if az aks get-credentials \
    --resource-group "${RESOURCE_GROUP}" \
    --name "${CLUSTER_NAME}" \
    --file "${kubeconfig_file}" \
    --overwrite-existing \
    --only-show-errors \
    >/dev/null 2>&1; then
    log "Fetched AKS kubeconfig for ${CLUSTER_NAME} into ${kubeconfig_file}"
  else
    fail "Failed to fetch AKS kubeconfig for ${CLUSTER_NAME}"
  fi

  export AKS_KUBECONFIG_FILE="${kubeconfig_file}"
  export KUBECONFIG="${kubeconfig_file}"
  write_generated_env AKS_KUBECONFIG_FILE "${kubeconfig_file}"
}

write_generated_env() {
  local key="$1"
  local value="$2"
  mkdir -p "$(dirname "${GENERATED_ENV_FILE}")"
  touch "${GENERATED_ENV_FILE}"

  if grep -q "^${key}=" "${GENERATED_ENV_FILE}"; then
    python3 - "$GENERATED_ENV_FILE" "$key" "$value" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
key = sys.argv[2]
value = sys.argv[3]
lines = path.read_text().splitlines()
updated = []
for line in lines:
    if line.startswith(f"{key}="):
        updated.append(f'{key}="{value}"')
    else:
        updated.append(line)
path.write_text("\n".join(updated) + "\n")
PY
  else
    printf '%s="%s"\n' "${key}" "${value}" >>"${GENERATED_ENV_FILE}"
  fi
}
