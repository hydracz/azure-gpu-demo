#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 10-create-aks.sh  —  创建 AKS 集群 (GPU, Karpenter 方案)
#
#   1. AKS 不开启 cluster-autoscaler
#   2. 仅创建 system 节点池, GPU 节点完全由 Karpenter 管理
#   3. 开启 OIDC Issuer + Workload Identity
#   4. 使用预创建的 VNet/Subnet 作为节点子网 (Azure CNI overlay + Cilium)
# ---------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../../common.sh"

load_env
ensure_tooling

: "${LOG_ANALYTICS_WORKSPACE_NAME:=log-${CLUSTER_NAME:-aks}-logs}"
: "${AKS_DIAGNOSTIC_SETTING_NAME:=aks-all-logs}"
: "${AKS_CREATE_RECOVERY_CHECKS:=12}"
: "${AKS_CREATE_RECOVERY_INTERVAL_SECONDS:=10}"
: "${AKS_ENABLE_BLOB_DRIVER:=true}"

[[ "${AKS_CREATE_RECOVERY_CHECKS}" =~ ^[0-9]+$ ]] || fail "AKS_CREATE_RECOVERY_CHECKS must be an integer, got: ${AKS_CREATE_RECOVERY_CHECKS}"
[[ "${AKS_CREATE_RECOVERY_INTERVAL_SECONDS}" =~ ^[0-9]+$ ]] || fail "AKS_CREATE_RECOVERY_INTERVAL_SECONDS must be an integer, got: ${AKS_CREATE_RECOVERY_INTERVAL_SECONDS}"
[[ "${AKS_ENABLE_BLOB_DRIVER}" == "true" || "${AKS_ENABLE_BLOB_DRIVER}" == "false" ]] || fail "AKS_ENABLE_BLOB_DRIVER must be true or false, got: ${AKS_ENABLE_BLOB_DRIVER}"

require_env \
  AZ_SUBSCRIPTION_ID LOCATION RESOURCE_GROUP CLUSTER_NAME ACR_NAME \
  MONITOR_WORKSPACE_NAME LOG_ANALYTICS_WORKSPACE_NAME AKS_DIAGNOSTIC_SETTING_NAME \
  GRAFANA_NAME SYSTEM_POOL_NAME SYSTEM_VM_SIZE SYSTEM_NODE_COUNT \
  VNET_SUBNET_ID

az account set --subscription "${AZ_SUBSCRIPTION_ID}" --only-show-errors
az extension add --name amg --upgrade --only-show-errors >/dev/null

resolve_current_principal_id() {
  local account_type account_name principal_id

  account_type="$(az account show --query user.type -o tsv --only-show-errors 2>/dev/null || true)"
  account_name="$(az account show --query user.name -o tsv --only-show-errors 2>/dev/null || true)"

  if [[ "${account_type}" == "user" ]]; then
    principal_id="$(az ad signed-in-user show --query id -o tsv --only-show-errors 2>/dev/null || true)"
  elif [[ "${account_type}" == "servicePrincipal" ]]; then
    if [[ "${account_name}" == "systemAssignedIdentity" ]]; then
      principal_id="$(python3 <<'PY'
import json
import urllib.request

url = "http://169.254.169.254/metadata/instance/compute?api-version=2021-02-01"
req = urllib.request.Request(url, headers={"Metadata": "true"})
try:
    with urllib.request.urlopen(req, timeout=5) as response:
        payload = json.load(response)
    print(payload.get("resourceId", ""))
except Exception:
    print("")
PY
)"
      [[ -n "${principal_id}" ]] || fail "Unable to resolve current VM resourceId from Azure instance metadata"
      principal_id="$(az resource show --ids "${principal_id}" --query identity.principalId -o tsv --only-show-errors 2>/dev/null || true)"
    else
      principal_id="$(az ad sp show --id "${account_name}" --query id -o tsv --only-show-errors 2>/dev/null || true)"
    fi
  fi

  [[ -n "${principal_id:-}" ]] || fail "Unable to resolve current Azure principal object id for Grafana admin assignment"
  printf '%s\n' "${principal_id}"
}

current_principal_id="$(resolve_current_principal_id)"

# ── 注册 Provider ──────────────────────────────────────────────────
log "Registering required Azure resource providers"
az provider register --namespace Microsoft.ContainerService --wait --only-show-errors >/dev/null
az provider register --namespace Microsoft.ContainerRegistry --wait --only-show-errors >/dev/null
az provider register --namespace Microsoft.Dashboard --wait --only-show-errors >/dev/null
az provider register --namespace Microsoft.Monitor --wait --only-show-errors >/dev/null
az provider register --namespace Microsoft.OperationalInsights --wait --only-show-errors >/dev/null
az provider register --namespace Microsoft.ManagedIdentity --wait --only-show-errors >/dev/null
az provider register --namespace Microsoft.Network --wait --only-show-errors >/dev/null

# ── Resource Group ─────────────────────────────────────────────────
log "Ensuring resource group ${RESOURCE_GROUP}"
az group create \
  --name "${RESOURCE_GROUP}" \
  --location "${LOCATION}" \
  --only-show-errors \
  >/dev/null

# ── ACR ────────────────────────────────────────────────────────────
if ! az acr show --name "${ACR_NAME}" --resource-group "${RESOURCE_GROUP}" --only-show-errors >/dev/null 2>&1; then
  log "Creating ACR ${ACR_NAME}"
  az acr create \
    --name "${ACR_NAME}" \
    --resource-group "${RESOURCE_GROUP}" \
    --location "${LOCATION}" \
    --sku Standard \
    --admin-enabled false \
    --only-show-errors \
    >/dev/null
else
  log "ACR ${ACR_NAME} already exists"
fi

# ── Azure Monitor Workspace ───────────────────────────────────────
if ! az monitor account show --name "${MONITOR_WORKSPACE_NAME}" --resource-group "${RESOURCE_GROUP}" --only-show-errors >/dev/null 2>&1; then
  log "Creating Azure Monitor Workspace ${MONITOR_WORKSPACE_NAME}"
  az monitor account create \
    --name "${MONITOR_WORKSPACE_NAME}" \
    --resource-group "${RESOURCE_GROUP}" \
    --location "${LOCATION}" \
    --only-show-errors \
    >/dev/null
else
  log "Azure Monitor Workspace ${MONITOR_WORKSPACE_NAME} already exists"
fi

# ── Log Analytics Workspace ───────────────────────────────────────
if ! az monitor log-analytics workspace show --name "${LOG_ANALYTICS_WORKSPACE_NAME}" --resource-group "${RESOURCE_GROUP}" --only-show-errors >/dev/null 2>&1; then
  log "Creating Log Analytics Workspace ${LOG_ANALYTICS_WORKSPACE_NAME}"
  az monitor log-analytics workspace create \
    --name "${LOG_ANALYTICS_WORKSPACE_NAME}" \
    --resource-group "${RESOURCE_GROUP}" \
    --location "${LOCATION}" \
    --only-show-errors \
    >/dev/null
else
  log "Log Analytics Workspace ${LOG_ANALYTICS_WORKSPACE_NAME} already exists"
fi

# ── Managed Grafana ───────────────────────────────────────────────
if ! az grafana show --name "${GRAFANA_NAME}" --resource-group "${RESOURCE_GROUP}" --only-show-errors >/dev/null 2>&1; then
  log "Creating Managed Grafana ${GRAFANA_NAME}"
  az grafana create \
    --name "${GRAFANA_NAME}" \
    --resource-group "${RESOURCE_GROUP}" \
    --location "${LOCATION}" \
    --sku-tier Standard \
    --public-network-access Enabled \
    --principal-ids "${current_principal_id}" \
    --only-show-errors \
    >/dev/null
else
  log "Managed Grafana ${GRAFANA_NAME} already exists"
fi

monitor_workspace_id="$(az monitor account show --name "${MONITOR_WORKSPACE_NAME}" --resource-group "${RESOURCE_GROUP}" --query id -o tsv --only-show-errors)"
log_analytics_workspace_id="$(az monitor log-analytics workspace show --name "${LOG_ANALYTICS_WORKSPACE_NAME}" --resource-group "${RESOURCE_GROUP}" --query id -o tsv --only-show-errors)"
grafana_id="$(az grafana show --name "${GRAFANA_NAME}" --resource-group "${RESOURCE_GROUP}" --query id -o tsv --only-show-errors)"

if ! az network vnet subnet show --ids "${VNET_SUBNET_ID}" --only-show-errors >/dev/null 2>&1; then
  fail "Custom subnet ${VNET_SUBNET_ID} not found. Run 05-create-network.sh first or set VNET_SUBNET_ID to an existing subnet."
fi

create_aks_cluster() {
  local create_output cluster_state attempt
  local -a blob_driver_args=()

  if [[ "${AKS_ENABLE_BLOB_DRIVER}" == "true" ]]; then
    blob_driver_args+=(--enable-blob-driver)
  fi

  if create_output="$(az aks create \
    --resource-group "${RESOURCE_GROUP}" \
    --name "${CLUSTER_NAME}" \
    --location "${LOCATION}" \
    --nodepool-name "${SYSTEM_POOL_NAME}" \
    --node-vm-size "${SYSTEM_VM_SIZE}" \
    --node-count "${SYSTEM_NODE_COUNT}" \
    --vnet-subnet-id "${VNET_SUBNET_ID}" \
    --network-plugin azure \
    --network-plugin-mode overlay \
    --network-dataplane cilium \
    --load-balancer-sku standard \
    --enable-managed-identity \
    --enable-oidc-issuer \
    --enable-workload-identity \
    --attach-acr "${ACR_NAME}" \
    --enable-keda \
    --enable-azure-monitor-metrics \
    --azure-monitor-workspace-resource-id "${monitor_workspace_id}" \
    --grafana-resource-id "${grafana_id}" \
    "${blob_driver_args[@]}" \
    --generate-ssh-keys \
    --only-show-errors \
    -o none 2>&1)"; then
    return 0
  fi

  if [[ "${create_output}" == *"RoleAssignmentExists"* ]]; then
    warn "az aks create reported RoleAssignmentExists; checking whether cluster ${CLUSTER_NAME} is already being created"

    for attempt in $(seq 1 "${AKS_CREATE_RECOVERY_CHECKS}"); do
      if aks_exists; then
        cluster_state="$(az aks show \
          --resource-group "${RESOURCE_GROUP}" \
          --name "${CLUSTER_NAME}" \
          --query provisioningState \
          -o tsv \
          --only-show-errors 2>/dev/null || true)"

        case "${cluster_state}" in
          Succeeded|Creating|Updating)
            warn "AKS cluster ${CLUSTER_NAME} exists with provisioningState=${cluster_state}; continuing despite RoleAssignmentExists from az aks create"
            return 0
            ;;
          Failed|Canceled)
            fail "AKS cluster ${CLUSTER_NAME} exists but provisioningState=${cluster_state} after az aks create reported RoleAssignmentExists"
            ;;
        esac
      fi

      sleep "${AKS_CREATE_RECOVERY_INTERVAL_SECONDS}"
    done
  fi

  fail "az aks create failed: ${create_output}"
}

# ── AKS 集群 (不开启 cluster-autoscaler) ─────────────────────────
if ! aks_exists; then
  log "Creating AKS cluster ${CLUSTER_NAME} with Azure CNI overlay + Cilium on custom subnet ${VNET_SUBNET_ID}"
  create_aks_cluster
else
  log "AKS cluster ${CLUSTER_NAME} already exists"
fi

blob_driver_status="$(az aks show \
  --resource-group "${RESOURCE_GROUP}" \
  --name "${CLUSTER_NAME}" \
  --query 'storageProfile.blobCsiDriver.enabled' \
  -o tsv \
  --only-show-errors 2>/dev/null || true)"

if [[ "${AKS_ENABLE_BLOB_DRIVER}" == "true" && "${blob_driver_status}" != "true" ]]; then
  log "Enabling Azure Blob CSI Driver on AKS cluster ${CLUSTER_NAME}"
  az aks update \
    --resource-group "${RESOURCE_GROUP}" \
    --name "${CLUSTER_NAME}" \
    --enable-blob-driver \
    --only-show-errors \
    >/dev/null
fi

wait_for_aks_ready

# ── Diagnostic Settings ───────────────────────────────────────────
cluster_id="$(az aks show --resource-group "${RESOURCE_GROUP}" --name "${CLUSTER_NAME}" --query id -o tsv --only-show-errors)"
diagnostic_log_categories="$(az monitor diagnostic-settings categories list \
  --resource "${cluster_id}" \
  --query "value[?categoryType=='Logs'].name" \
  -o tsv \
  --only-show-errors)"
diagnostic_logs_json="$(python3 - "${diagnostic_log_categories}" <<'PY'
import json
import sys

categories = [line.strip() for line in sys.argv[1].splitlines() if line.strip()]
if not categories:
    raise SystemExit("No AKS log categories were returned for diagnostic settings.")

payload = [{"category": category, "enabled": True} for category in categories]
print(json.dumps(payload, separators=(",", ":")))
PY
)"

log "Enabling all AKS control plane log categories in Log Analytics Workspace ${LOG_ANALYTICS_WORKSPACE_NAME}"
az monitor diagnostic-settings create \
  --name "${AKS_DIAGNOSTIC_SETTING_NAME}" \
  --resource "${cluster_id}" \
  --workspace "${log_analytics_workspace_id}" \
  --logs "${diagnostic_logs_json}" \
  --only-show-errors \
  >/dev/null

# ── 获取 kubeconfig ───────────────────────────────────────────────
log "Fetching kubeconfig"
az aks get-credentials \
  --resource-group "${RESOURCE_GROUP}" \
  --name "${CLUSTER_NAME}" \
  --overwrite-existing \
  --only-show-errors \
  >/dev/null

log "Installing ServiceMonitor CRD (prometheus-operator)"
if ! kubectl apply -f "${ROOT_DIR}/01-environment/charts/crd-servicemonitors.yaml" --validate=false >/dev/null 2>&1; then
  warn "Failed to apply ServiceMonitor CRD; continue and run manually if needed"
fi

log "Applying AMA metrics settings ConfigMap"
kubectl apply -f "${ROOT_DIR}/01-environment/charts/ama-metrics-settings-configmap.yaml" >/dev/null

# ── 保存集群信息到 .generated.env ─────────────────────────────────
aks_oidc_issuer="$(az aks show --resource-group "${RESOURCE_GROUP}" --name "${CLUSTER_NAME}" --query "oidcIssuerProfile.issuerUrl" -o tsv --only-show-errors)"
aks_endpoint="$(az aks show --resource-group "${RESOURCE_GROUP}" --name "${CLUSTER_NAME}" --query "fqdn" -o tsv --only-show-errors)"
node_resource_group="$(az aks show --resource-group "${RESOURCE_GROUP}" --name "${CLUSTER_NAME}" --query "nodeResourceGroup" -o tsv --only-show-errors)"

write_generated_env AKS_OIDC_ISSUER "${aks_oidc_issuer}"
write_generated_env AKS_ENDPOINT "https://${aks_endpoint}"
write_generated_env NODE_RESOURCE_GROUP "${node_resource_group}"
write_generated_env VNET_SUBNET_ID "${VNET_SUBNET_ID}"

log "Cluster bootstrap completed (no cluster-autoscaler, no user node pools)"
log "AKS network mode      → Azure CNI overlay + Cilium"
log "AKS Blob CSI Driver   → ${AKS_ENABLE_BLOB_DRIVER}"
log "AKS node subnet       → ${VNET_SUBNET_ID}"
log "AKS diagnostic logs → Log Analytics Workspace ${LOG_ANALYTICS_WORKSPACE_NAME}"
log "Next step: run 01-environment/shell/15-deploy-karpenter.sh to deploy Karpenter"
kubectl get nodes -L agentpool
