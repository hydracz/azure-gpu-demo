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

  set_default_env AKS_DIAGNOSTIC_SETTING_NAME "aks-all-logs"
  set_default_env TFSTATE_CONTAINER "tfstate"
  set_default_env TFSTATE_USE_AZUREAD_AUTH "true"
  set_default_env MONITOR_WORKSPACE_PUBLIC_NETWORK_ACCESS_ENABLED "true"
  set_default_env GRAFANA_MAJOR_VERSION "12"
  set_default_env SYSTEM_POOL_NAME "sysd4"
  set_default_env SYSTEM_VM_SIZE "Standard_D4ads_v6"
  set_default_env SYSTEM_NODE_COUNT "3"
  set_default_env AKS_ADMIN_USERNAME "azureuser"
  set_default_env VNET_ADDRESS_PREFIX "10.240.0.0/16"
  set_default_env AKS_SUBNET_NAME "snet-aks-underlay"
  set_default_env AKS_SUBNET_ADDRESS_PREFIX "10.240.0.0/20"
  set_default_env SERVICE_CIDR "172.16.32.0/19"
  set_default_env DNS_SERVICE_IP "172.16.32.10"
  set_default_env AKS_ENABLE_BLOB_DRIVER "true"
  set_default_env AKS_MANAGED_GATEWAY_API_ENABLED "true"
  set_default_env ISTIO_SERVICE_MESH_ENABLED "true"
  set_default_env ISTIO_REVISIONS_CSV "asm-1-27"
  set_default_env SERVICE_MESH_REVISIONS_CSV "${ISTIO_REVISIONS_CSV}"
  set_default_env ISTIO_INTERNAL_INGRESS_GATEWAY_ENABLED "true"
  set_default_env ISTIO_EXTERNAL_INGRESS_GATEWAY_ENABLED "true"
  set_default_env ISTIO_INTERNAL_INGRESS_GATEWAY_MIN_REPLICAS "2"
  set_default_env ISTIO_INTERNAL_INGRESS_GATEWAY_MAX_REPLICAS "5"
  set_default_env ISTIO_EXTERNAL_INGRESS_GATEWAY_MIN_REPLICAS "2"
  set_default_env ISTIO_EXTERNAL_INGRESS_GATEWAY_MAX_REPLICAS "5"
  set_default_env ISTIO_KIALI_ENABLED "true"
  set_default_env ISTIO_KIALI_NAMESPACE "aks-istio-system"
  set_default_env ISTIO_KIALI_REPLICAS "1"
  set_default_env ISTIO_KIALI_VIEW_ONLY_MODE "true"
  set_default_env ISTIO_KIALI_OPERATOR_CHART_VERSION "2.20.0"
  set_default_env ISTIO_KIALI_PROMETHEUS_RETENTION_PERIOD "30d"
  set_default_env ISTIO_KIALI_PROMETHEUS_SCRAPE_INTERVAL "30s"
  set_default_env ISTIO_KIALI_PROXY_IDENTITY_NAME "id-aks-istio-kiali-proxy"
  set_default_env ISTIO_KIALI_PROXY_SERVICE_ACCOUNT_NAME "azuremonitor-query"
  set_default_env ISTIO_KIALI_PROXY_SERVICE_NAME "azuremonitor-query"
  set_default_env GRAFANA_ADMIN_PRINCIPAL_IDS ""
  set_default_env GRAFANA_DASHBOARD_IMPORT_ENABLED "true"
  set_default_env PROMETHEUS_RULE_GROUP_ENABLED "true"
  set_default_env PROMETHEUS_RULE_GROUP_INTERVAL "PT1M"
  set_default_env SERVICE_MONITOR_CRD_ENABLED "true"
  set_default_env KEDA_PROMETHEUS_AUTH_NAME "azure-managed-prometheus"
  set_default_env KEDA_PROMETHEUS_IDENTITY_NAME "id-keda-prometheus"
  set_default_env KEDA_PROMETHEUS_OPERATOR_NAMESPACE "kube-system"
  set_default_env KEDA_PROMETHEUS_OPERATOR_SERVICE_ACCOUNT_NAME "keda-operator"
  set_default_env KEDA_PROMETHEUS_OPERATOR_DEPLOYMENT_NAME "keda-operator"
  set_default_env KEDA_PROMETHEUS_FEDERATED_CREDENTIAL_NAME "${KEDA_PROMETHEUS_IDENTITY_NAME}-keda-operator"
  set_default_env CERT_MANAGER_ENABLED "true"
  set_default_env CERT_MANAGER_STAGING_ISSUER_NAME "letsencrypt-staging"
  set_default_env CERT_MANAGER_PROD_ISSUER_NAME "letsencrypt-prod"
  set_default_env IMAGE_SYNC_TOOL "az-acr-import"

  set_default_env KARPENTER_NAMESPACE "kube-system"
  set_default_env KARPENTER_SERVICE_ACCOUNT "karpenter-sa"
  set_default_env KARPENTER_IMAGE_REPO "quay.io/hydracz/karpenter-controller"
  set_default_env KARPENTER_IMAGE_REPOSITORY "${KARPENTER_IMAGE_REPO}"
  set_default_env KARPENTER_IMAGE_TAG "v20260323-dev"

  set_default_env GPU_SKU_NAME "Standard_NC128lds_xl_RTXPRO6000BSE_v6"
  set_default_env GPU_TYPE "rtxpro6000-bse"
  if [[ -z "${GPU_ZONES:-}" && -n "${LOCATION:-}" ]]; then
    set_default_env GPU_ZONES "${LOCATION}-1"
  fi
  set_default_env GPU_NODE_IMAGE_FAMILY "Ubuntu2404"
  set_default_env GPU_OS_DISK_SIZE_GB "1024"
  set_default_env INSTALL_GPU_DRIVERS "false"
  set_default_env CONSOLIDATE_AFTER "10m"
  set_default_env SPOT_MAX_PRICE "-1"
  set_default_env GPU_OPERATOR_ENABLED "true"
  set_default_env GPU_OPERATOR_NAMESPACE "gpu-operator"
  set_default_env GPU_DRIVER_CR_NAME "rtxpro6000-azure"
  set_default_env GPU_DRIVER_NODE_SELECTOR_KEY "karpenter.azure.com/sku-gpu-name"
  set_default_env GPU_DRIVER_NODE_SELECTOR_VALUE ""
  set_default_env GPU_DRIVER_SOURCE_REPOSITORY "docker.io/yingeli"
  set_default_env GPU_DRIVER_IMAGE "driver"
  set_default_env GPU_DRIVER_VERSION "580.105.08"
  set_default_env GPU_DRIVER_REQUIRE_MATCHING_NODES "false"
  set_default_env GPU_DRIVER_SYNC_ENABLED "true"
  set_default_env GPU_DRIVER_SYNC_USE_SUDO "false"
  set_default_env GPU_DRIVER_ALLOW_OS_TAG_ALIAS "false"
  set_default_env GPU_DRIVER_VERSION_SOURCE_TAG_2204 "${GPU_DRIVER_VERSION}-ubuntu22.04"
  set_default_env GPU_DRIVER_VERSION_SOURCE_TAG_2404 "${GPU_DRIVER_VERSION}-ubuntu24.04"

  set_default_env GPU_NODE_WORKLOAD_LABEL "gpu-test"
  set_default_env APP_NODE_WORKLOAD_LABEL "${GPU_NODE_WORKLOAD_LABEL}"
  set_default_env QWEN_LOADTEST_NODE_WORKLOAD_LABEL "${GPU_NODE_WORKLOAD_LABEL}"

  set_default_env APP_NAMESPACE "gpu-test"
  set_default_env APP_NAME "gpu-probe"
  set_default_env TEST_IMAGE_REPOSITORY "aks/gpu-probe"
  set_default_env TEST_IMAGE_TAG "latest"
  set_default_env APP_MIN_REPLICAS "1"
  set_default_env APP_MAX_REPLICAS "2"
  set_default_env APP_REQUEST_CPU "1000m"
  set_default_env APP_LIMIT_CPU "2000m"
  set_default_env APP_REQUEST_MEMORY "4Gi"
  set_default_env APP_LIMIT_MEMORY "8Gi"
  set_default_env APP_REQUEST_GPU "1"
  set_default_env LOCAL_FORWARD_PORT "18080"

  set_default_env QWEN_LOADTEST_NAMESPACE "qwen-loadtest"
  set_default_env QWEN_LOADTEST_NAME "qwen-loadtest-target"
  set_default_env QWEN_LOADTEST_SERVICE_NAME "${QWEN_LOADTEST_NAME}"
  set_default_env QWEN_LOADTEST_SOURCE_LOGIN_SERVER "qwenloadtestsea3414.azurecr.io"
  set_default_env QWEN_LOADTEST_SOURCE_USERNAME "${QWEN_LOADTEST_SOURCE_LOGIN_SERVER%%.*}"
  set_default_env QWEN_LOADTEST_SOURCE_IMAGE_REPOSITORY "qwen-loadtest-target"
  set_default_env QWEN_LOADTEST_SOURCE_IMAGE_TAG "sea-a100-failfast-20260413"
  set_default_env QWEN_LOADTEST_TARGET_REPOSITORY "aks/qwen-loadtest-target"
  set_default_env QWEN_LOADTEST_CONTAINER_PORT "8080"
  set_default_env QWEN_LOADTEST_SERVICE_PORT "8080"
  set_default_env QWEN_LOADTEST_GATEWAY_NAME "qwen-loadtest-external"
  set_default_env QWEN_LOADTEST_GATEWAY_CLASS_NAME "istio"
  set_default_env QWEN_LOADTEST_TLS_SECRET_NAME "qwen-loadtest-target-tls"
  set_default_env QWEN_LOADTEST_CERTIFICATE_NAME "${QWEN_LOADTEST_TLS_SECRET_NAME}"
  set_default_env QWEN_LOADTEST_CERT_ISSUER_NAME "${CERT_MANAGER_PROD_ISSUER_NAME}"
  set_default_env QWEN_LOADTEST_GATEWAY_NAMESPACE "${QWEN_LOADTEST_NAMESPACE}"
  set_default_env QWEN_LOADTEST_GATEWAY_WORKLOAD_NAME "${QWEN_LOADTEST_GATEWAY_NAME}"
  set_default_env QWEN_LOADTEST_KEDA_AUTH_NAME "${KEDA_PROMETHEUS_AUTH_NAME}"
  set_default_env QWEN_LOADTEST_KEDA_OPERATOR_NAMESPACE "${KEDA_PROMETHEUS_OPERATOR_NAMESPACE}"
  set_default_env QWEN_LOADTEST_KEDA_OPERATOR_SERVICE_ACCOUNT_NAME "${KEDA_PROMETHEUS_OPERATOR_SERVICE_ACCOUNT_NAME}"
  set_default_env QWEN_LOADTEST_MIN_REPLICAS "1"
  set_default_env QWEN_LOADTEST_MAX_REPLICAS "8"
  set_default_env QWEN_LOADTEST_POLLING_INTERVAL "5"
  set_default_env QWEN_LOADTEST_COOLDOWN_PERIOD "60"
  set_default_env QWEN_LOADTEST_KEDA_THRESHOLD "1"
  set_default_env QWEN_LOADTEST_KEDA_ACTIVATION_THRESHOLD "1"
  set_default_env QWEN_LOADTEST_GPU_REQUEST "1"
  set_default_env QWEN_LOADTEST_CPU_REQUEST "4"
  set_default_env QWEN_LOADTEST_CPU_LIMIT "8"
  set_default_env QWEN_LOADTEST_MEMORY_REQUEST "24Gi"
  set_default_env QWEN_LOADTEST_MEMORY_LIMIT "32Gi"
  set_default_env QWEN_LOADTEST_TEST_CONCURRENCY "2"
  set_default_env QWEN_LOADTEST_TEST_REQUEST_TIMEOUT "180"
  set_default_env QWEN_LOADTEST_TEST_MODE "predict"
  set_default_env QWEN_LOADTEST_TEST_PATH "/predict"
  set_default_env QWEN_LOADTEST_TEST_VIA_CLUSTER_GATEWAY "true"
  if [[ -z "${QWEN_LOADTEST_GPU_TYPE:-}" && -n "${GPU_TYPE:-}" ]]; then
    set_default_env QWEN_LOADTEST_GPU_TYPE "${GPU_TYPE}"
  fi
  if [[ -z "${QWEN_LOADTEST_ISTIO_REVISION:-}" && -n "${ISTIO_REVISIONS_CSV:-}" ]]; then
    set_default_env QWEN_LOADTEST_ISTIO_REVISION "${ISTIO_REVISIONS_CSV%%,*}"
  fi

  set_default_env TAGS_ENVIRONMENT "dev"
  set_default_env TAGS_OWNER "platform"
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

