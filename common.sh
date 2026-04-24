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

sanitize_stack_id() {
  local raw_value="${1:-}"
  local sanitized

  sanitized="$(printf '%s' "${raw_value}" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-')"
  sanitized="${sanitized#-}"
  sanitized="${sanitized%-}"
  printf '%s\n' "${sanitized}"
}

compact_lower_alnum() {
  printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9'
}

first_csv_item() {
  local raw_value="${1:-}"
  local first_item=""

  IFS=',' read -r first_item _ <<<"${raw_value}"
  printf '%s\n' "${first_item}"
}

resolve_gpu_node_class() {
  printf '%s\n' "${GPU_NODE_CLASS:-${GPU_NODE_WORKLOAD_LABEL:-gpu}}"
}

derive_gpu_node_sku_label_value() {
  local selector_value="${1:-${GPU_NODE_SKU_LABEL_VALUE:-${GPU_DRIVER_NODE_SELECTOR_VALUE:-}}}"
  local gpu_sku_name="${2:-${GPU_SKU_NAME:-}}"
  local -a gpu_sku_parts=()

  if [[ -n "${selector_value}" ]]; then
    printf '%s\n' "${selector_value}"
    return 0
  fi

  if [[ -z "${gpu_sku_name}" ]]; then
    return 0
  fi

  IFS='_' read -r -a gpu_sku_parts <<<"${gpu_sku_name}"
  if (( ${#gpu_sku_parts[@]} >= 2 )); then
    printf '%s\n' "${gpu_sku_parts[${#gpu_sku_parts[@]}-2]}"
  fi
}

set_default_env() {
  local name="$1"
  local value="$2"

  if [[ -z "${!name:-}" ]]; then
    printf -v "${name}" '%s' "${value}"
    export "${name}"
  fi
}

apply_derived_config() {
  local stack_id="${STACK_ID:-}"
  local compact_stack_id=""

  if [[ -n "${stack_id}" ]]; then
    stack_id="$(sanitize_stack_id "${stack_id}")"
    [[ -n "${stack_id}" ]] || fail "STACK_ID must contain at least one alphanumeric character"

    compact_stack_id="$(compact_lower_alnum "${stack_id}")"
    (( ${#compact_stack_id} <= 47 )) || fail "STACK_ID ${stack_id} is too long to derive a valid ACR name"

    set_default_env STACK_ID "${stack_id}"
    set_default_env RESOURCE_GROUP "rg-aks-${stack_id}"
    set_default_env NETWORK_RESOURCE_GROUP "rg-aks-${stack_id}-net"
    set_default_env CLUSTER_NAME "aks-${stack_id}"
    set_default_env ACR_NAME "acr${compact_stack_id}"
    set_default_env MONITOR_WORKSPACE_NAME "amw-aks-${stack_id}"
    set_default_env LOG_ANALYTICS_WORKSPACE_NAME "log-aks-${stack_id}"
    set_default_env GRAFANA_NAME "amg-aks-${stack_id}"
    set_default_env VNET_NAME "vnet-aks-${stack_id}"
    set_default_env KARPENTER_IDENTITY_NAME "id-${stack_id}"
    set_default_env AKS_IDENTITY_NAME "id-aks-${stack_id}"
    set_default_env KEDA_PROMETHEUS_IDENTITY_NAME "id-${stack_id}-keda-prom"
  fi

  set_default_env TFSTATE_CONTAINER "tfstate"
  set_default_env TFSTATE_USE_AZUREAD_AUTH "true"
}

load_env() {
  if [[ ! -f "${ENV_FILE}" ]]; then
    fail "missing env file: ${ENV_FILE}. Copy aks.env.sample to aks.env first, or set AKS_ENV_FILE to an existing env file."
  fi

  set -a
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
  apply_derived_config
  if [[ -f "${GENERATED_ENV_FILE}" ]]; then
    # shellcheck disable=SC1090
    source "${GENERATED_ENV_FILE}"
  fi
  apply_derived_config
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

resolve_current_azure_principal_id() {
  local account_type=""
  local account_name=""
  local principal_id=""
  local resource_id=""

  need_cmd az

  account_type="$(az account show --query user.type -o tsv --only-show-errors 2>/dev/null || true)"
  account_name="$(az account show --query user.name -o tsv --only-show-errors 2>/dev/null || true)"

  if [[ "${account_type}" == "user" ]]; then
    principal_id="$(az ad signed-in-user show --query id -o tsv --only-show-errors 2>/dev/null || true)"
  elif [[ "${account_type}" == "servicePrincipal" ]]; then
    if [[ "${account_name}" == "systemAssignedIdentity" ]]; then
      need_cmd python3
      resource_id="$(python3 <<'PY'
import json
import urllib.request

url = "http://169.254.169.254/metadata/instance/compute?api-version=2021-02-01"
request = urllib.request.Request(url, headers={"Metadata": "true"})
try:
    with urllib.request.urlopen(request, timeout=5) as response:
        payload = json.load(response)
    print(payload.get("resourceId", ""))
except Exception:
    print("")
PY
)"
      [[ -n "${resource_id}" ]] || fail "Unable to resolve current VM resourceId from Azure instance metadata"
      principal_id="$(az resource show --ids "${resource_id}" --query identity.principalId -o tsv --only-show-errors 2>/dev/null || true)"
    else
      principal_id="$(az ad sp show --id "${account_name}" --query id -o tsv --only-show-errors 2>/dev/null || true)"
    fi
  fi

  [[ -n "${principal_id}" ]] || fail "Unable to resolve current Azure principal object id"
  printf '%s\n' "${principal_id}"
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

kubeconfig_file_exists() {
  local kubeconfig_file="$1"

  [[ -s "${kubeconfig_file}" ]]
}

try_ensure_aks_kubeconfig() {
  local kubeconfig_file
  local fetched_mode=""

  kubeconfig_file="${1:-$(resolve_aks_kubeconfig_file)}"
  ensure_parent_dir "${kubeconfig_file}"

  if kubeconfig_file_exists "${kubeconfig_file}"; then
    export AKS_KUBECONFIG_FILE="${kubeconfig_file}"
    export KUBECONFIG="${kubeconfig_file}"
    write_generated_env AKS_KUBECONFIG_FILE "${kubeconfig_file}"
    log "Reusing existing kubeconfig ${kubeconfig_file} for ${CLUSTER_NAME:-cluster}"
    return 0
  fi

  need_cmd az
  need_cmd kubectl
  require_env AZ_SUBSCRIPTION_ID RESOURCE_GROUP CLUSTER_NAME

  az account set --subscription "${AZ_SUBSCRIPTION_ID}" --only-show-errors >/dev/null
  if az aks get-credentials \
    --resource-group "${RESOURCE_GROUP}" \
    --name "${CLUSTER_NAME}" \
    --file "${kubeconfig_file}" \
    --overwrite-existing \
    --admin \
    --only-show-errors \
    >/dev/null 2>&1; then
    fetched_mode="admin"
  else
    warn "Falling back to user kubeconfig for ${CLUSTER_NAME}"
    if az aks get-credentials \
      --resource-group "${RESOURCE_GROUP}" \
      --name "${CLUSTER_NAME}" \
      --file "${kubeconfig_file}" \
      --overwrite-existing \
      --only-show-errors \
      >/dev/null 2>&1; then
      fetched_mode="user"
    else
      return 1
    fi
  fi

  log "Fetched AKS ${fetched_mode} kubeconfig for ${CLUSTER_NAME} into ${kubeconfig_file}"

  export AKS_KUBECONFIG_FILE="${kubeconfig_file}"
  export KUBECONFIG="${kubeconfig_file}"
  write_generated_env AKS_KUBECONFIG_FILE "${kubeconfig_file}"

  return 0
}

ensure_aks_kubeconfig() {
  local kubeconfig_file

  kubeconfig_file="${1:-$(resolve_aks_kubeconfig_file)}"

  if ! try_ensure_aks_kubeconfig "${kubeconfig_file}"; then
    fail "Failed to fetch AKS kubeconfig for ${CLUSTER_NAME:-cluster}"
  fi
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

def shell_double_quote(raw: str) -> str:
  return raw.replace('\\', '\\\\').replace('"', '\\"').replace('$', '\\$').replace('`', '\\`')

lines = path.read_text().splitlines()
updated = []
for line in lines:
    if line.startswith(f"{key}="):
        updated.append(f'{key}="{shell_double_quote(value)}"')
    else:
        updated.append(line)
path.write_text("\n".join(updated) + "\n")
PY
  else
    python3 - "${GENERATED_ENV_FILE}" "${key}" "${value}" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
key = sys.argv[2]
value = sys.argv[3]

def shell_double_quote(raw: str) -> str:
  return raw.replace('\\', '\\\\').replace('"', '\\"').replace('$', '\\$').replace('`', '\\`')

with path.open('a', encoding='utf-8') as handle:
  handle.write(f'{key}="{shell_double_quote(value)}"\n')
PY
  fi
}

refresh_qwen_loadtest_gateway_access() {
  local gateway_namespace="$1"
  local gateway_service="$2"
  local workload_name="$3"
  local current_gateway_ip=""
  local gateway_scheme="${QWEN_LOADTEST_GATEWAY_SCHEME:-http}"
  local current_host="${QWEN_LOADTEST_HOST:-${workload_name}.internal}"

  current_gateway_ip="$(kubectl -n "${gateway_namespace}" get svc "${gateway_service}" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
  [[ -n "${current_gateway_ip}" ]] || return 0

  if [[ -z "${QWEN_LOADTEST_GATEWAY_IP:-}" || "${QWEN_LOADTEST_GATEWAY_IP}" != "${current_gateway_ip}" ]]; then
    QWEN_LOADTEST_GATEWAY_IP="${current_gateway_ip}"
    write_generated_env QWEN_LOADTEST_GATEWAY_IP "${QWEN_LOADTEST_GATEWAY_IP}"
  fi

  if [[ -z "${QWEN_LOADTEST_HOST:-}" || "${QWEN_LOADTEST_HOST}" == "${workload_name}."*.sslip.io ]]; then
    QWEN_LOADTEST_HOST="${workload_name}.internal"
    current_host="${QWEN_LOADTEST_HOST}"
    write_generated_env QWEN_LOADTEST_HOST "${QWEN_LOADTEST_HOST}"
  fi

  QWEN_LOADTEST_URL="${gateway_scheme}://${current_host}"
  write_generated_env QWEN_LOADTEST_URL "${QWEN_LOADTEST_URL}"
}

resolve_qwen_loadtest_gateway_target_ip() {
  local gateway_namespace="$1"
  local gateway_service="$2"
  local via_cluster_gateway="$3"

  if [[ "${via_cluster_gateway}" == "true" ]]; then
    kubectl -n "${gateway_namespace}" get svc "${gateway_service}" -o jsonpath='{.spec.clusterIP}'
    return 0
  fi

  printf '%s\n' "${QWEN_LOADTEST_GATEWAY_IP:-}"
}

