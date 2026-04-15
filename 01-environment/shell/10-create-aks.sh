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
: "${ISTIO_SERVICE_MESH_ENABLED:=true}"
: "${ISTIO_REVISIONS_CSV:=${SERVICE_MESH_REVISIONS_CSV:-asm-1-27}}"
: "${ISTIO_EXTERNAL_INGRESS_GATEWAY_ENABLED:=true}"
: "${ISTIO_INTERNAL_INGRESS_GATEWAY_ENABLED:=true}"
: "${KEDA_PROMETHEUS_AUTH_NAME:=azure-managed-prometheus}"
: "${KEDA_PROMETHEUS_IDENTITY_NAME:=id-keda-prometheus}"
: "${KEDA_PROMETHEUS_OPERATOR_NAMESPACE:=kube-system}"
: "${KEDA_PROMETHEUS_OPERATOR_SERVICE_ACCOUNT_NAME:=keda-operator}"
: "${KEDA_PROMETHEUS_OPERATOR_DEPLOYMENT_NAME:=keda-operator}"
: "${KEDA_PROMETHEUS_FEDERATED_CREDENTIAL_NAME:=${KEDA_PROMETHEUS_IDENTITY_NAME}-keda-operator}"

[[ "${AKS_CREATE_RECOVERY_CHECKS}" =~ ^[0-9]+$ ]] || fail "AKS_CREATE_RECOVERY_CHECKS must be an integer, got: ${AKS_CREATE_RECOVERY_CHECKS}"
[[ "${AKS_CREATE_RECOVERY_INTERVAL_SECONDS}" =~ ^[0-9]+$ ]] || fail "AKS_CREATE_RECOVERY_INTERVAL_SECONDS must be an integer, got: ${AKS_CREATE_RECOVERY_INTERVAL_SECONDS}"
[[ "${AKS_ENABLE_BLOB_DRIVER}" == "true" || "${AKS_ENABLE_BLOB_DRIVER}" == "false" ]] || fail "AKS_ENABLE_BLOB_DRIVER must be true or false, got: ${AKS_ENABLE_BLOB_DRIVER}"
[[ "${ISTIO_SERVICE_MESH_ENABLED}" == "true" || "${ISTIO_SERVICE_MESH_ENABLED}" == "false" ]] || fail "ISTIO_SERVICE_MESH_ENABLED must be true or false, got: ${ISTIO_SERVICE_MESH_ENABLED}"
[[ "${ISTIO_EXTERNAL_INGRESS_GATEWAY_ENABLED}" == "true" || "${ISTIO_EXTERNAL_INGRESS_GATEWAY_ENABLED}" == "false" ]] || fail "ISTIO_EXTERNAL_INGRESS_GATEWAY_ENABLED must be true or false, got: ${ISTIO_EXTERNAL_INGRESS_GATEWAY_ENABLED}"
[[ "${ISTIO_INTERNAL_INGRESS_GATEWAY_ENABLED}" == "true" || "${ISTIO_INTERNAL_INGRESS_GATEWAY_ENABLED}" == "false" ]] || fail "ISTIO_INTERNAL_INGRESS_GATEWAY_ENABLED must be true or false, got: ${ISTIO_INTERNAL_INGRESS_GATEWAY_ENABLED}"

require_env \
  AZ_SUBSCRIPTION_ID LOCATION RESOURCE_GROUP CLUSTER_NAME ACR_NAME \
  MONITOR_WORKSPACE_NAME LOG_ANALYTICS_WORKSPACE_NAME AKS_DIAGNOSTIC_SETTING_NAME \
  GRAFANA_NAME SYSTEM_POOL_NAME SYSTEM_VM_SIZE SYSTEM_NODE_COUNT \
  VNET_SUBNET_ID

ensure_az_extension() {
  local extension_name="$1"

  if az extension show --name "${extension_name}" --only-show-errors >/dev/null 2>&1; then
    log "Azure CLI extension ${extension_name} already installed"
    return 0
  fi

  log "Installing Azure CLI extension ${extension_name}"
  az extension add --name "${extension_name}" --only-show-errors >/dev/null
}

resolve_desired_istio_revision() {
  local revision="${ISTIO_REVISIONS_CSV:-${SERVICE_MESH_REVISIONS_CSV:-}}"

  IFS=',' read -r revision _ <<<"${revision}"
  [[ -n "${revision}" ]] || fail "ISTIO_REVISIONS_CSV must contain at least one Azure Service Mesh revision"
  printf '%s\n' "${revision}"
}

wait_for_namespace() {
  local namespace="$1"
  local attempts="${2:-60}"
  local attempt

  for attempt in $(seq 1 "${attempts}"); do
    if kubectl get namespace "${namespace}" >/dev/null 2>&1; then
      return 0
    fi

    warn "Waiting for namespace ${namespace} (${attempt}/${attempts})"
    sleep 10
  done

  fail "Namespace ${namespace} was not created in time"
}

wait_for_service() {
  local namespace="$1"
  local name="$2"
  local attempts="${3:-60}"
  local attempt

  for attempt in $(seq 1 "${attempts}"); do
    if kubectl get service "${name}" -n "${namespace}" >/dev/null 2>&1; then
      return 0
    fi

    warn "Waiting for service ${namespace}/${name} (${attempt}/${attempts})"
    sleep 10
  done

  fail "Service ${namespace}/${name} was not created in time"
}

wait_for_deployment() {
  local namespace="$1"
  local name="$2"
  local attempts="${3:-60}"
  local attempt

  for attempt in $(seq 1 "${attempts}"); do
    if kubectl get deployment "${name}" -n "${namespace}" >/dev/null 2>&1; then
      return 0
    fi

    warn "Waiting for deployment ${namespace}/${name} (${attempt}/${attempts})"
    sleep 10
  done

  fail "Deployment ${namespace}/${name} was not created in time"
}

wait_for_crd() {
  local name="$1"
  local attempts="${2:-60}"
  local attempt

  for attempt in $(seq 1 "${attempts}"); do
    if kubectl get crd "${name}" >/dev/null 2>&1; then
      return 0
    fi

    warn "Waiting for CRD ${name} (${attempt}/${attempts})"
    sleep 10
  done

  fail "CRD ${name} was not created in time"
}

current_service_mesh_revisions() {
  kubectl get mutatingwebhookconfigurations -o name 2>/dev/null |
    grep -oE 'asm-[0-9]+-[0-9]+' |
    sort -u |
    paste -sd, - || true
}

wait_for_service_mesh_revision() {
  local revision="$1"
  local attempts="${2:-60}"
  local attempt
  local revisions

  for attempt in $(seq 1 "${attempts}"); do
    revisions="$(current_service_mesh_revisions)"
    if [[ ",${revisions}," == *",${revision},"* ]]; then
      return 0
    fi

    warn "Waiting for Azure Service Mesh revision ${revision} (${attempt}/${attempts})"
    sleep 10
  done

  fail "Azure Service Mesh revision ${revision} was not ready in time"
}

keda_operator_client_id_annotation() {
  kubectl get serviceaccount "${KEDA_PROMETHEUS_OPERATOR_SERVICE_ACCOUNT_NAME}" \
    -n "${KEDA_PROMETHEUS_OPERATOR_NAMESPACE}" \
    -o jsonpath="{.metadata.annotations['azure\.workload\.identity/client-id']}" 2>/dev/null || true
}

keda_operator_use_label() {
  kubectl get deployment "${KEDA_PROMETHEUS_OPERATOR_DEPLOYMENT_NAME}" \
    -n "${KEDA_PROMETHEUS_OPERATOR_NAMESPACE}" \
    -o jsonpath="{.spec.template.metadata.labels['azure\.workload\.identity/use']}" 2>/dev/null || true
}

keda_operator_has_workload_identity_env() {
  local env_names

  env_names="$(kubectl get pods -n "${KEDA_PROMETHEUS_OPERATOR_NAMESPACE}" -l app.kubernetes.io/name=keda-operator -o jsonpath='{.items[0].spec.containers[0].env[*].name}' 2>/dev/null || true)"
  [[ "${env_names}" == *AZURE_FEDERATED_TOKEN_FILE* ]]
}

ensure_azure_service_mesh() {
  local attempt
  local current_revisions=""

  [[ "${ISTIO_SERVICE_MESH_ENABLED}" == "true" ]] || return 0

  current_revisions="$(current_service_mesh_revisions)"
  if [[ -z "${current_revisions}" && "${aks_cluster_created:-false}" == "true" ]]; then
    for attempt in $(seq 1 18); do
      current_revisions="$(current_service_mesh_revisions)"
      if [[ ",${current_revisions}," == *",${desired_istio_revision},"* ]]; then
        break
      fi

      warn "Waiting for Azure Service Mesh revision ${desired_istio_revision} from initial cluster provisioning (${attempt}/18)"
      sleep 10
    done
  fi

  if [[ -n "${current_revisions}" && ",${current_revisions}," != *",${desired_istio_revision},"* ]]; then
    fail "AKS cluster ${CLUSTER_NAME} already exposes Azure Service Mesh revision(s) ${current_revisions}, expected ${desired_istio_revision}. Recreate or upgrade the cluster before continuing."
  fi

  if [[ -z "${current_revisions}" ]]; then
    log "Enabling Azure Service Mesh revision ${desired_istio_revision}"
    az aks mesh enable \
      --resource-group "${RESOURCE_GROUP}" \
      --name "${CLUSTER_NAME}" \
      --revision "${desired_istio_revision}" \
      --only-show-errors \
      >/dev/null
  else
    log "Azure Service Mesh revision ${desired_istio_revision} already enabled"
  fi

  wait_for_namespace aks-istio-system
  wait_for_namespace aks-istio-ingress
  wait_for_service_mesh_revision "${desired_istio_revision}"

  if [[ "${ISTIO_EXTERNAL_INGRESS_GATEWAY_ENABLED}" == "true" ]]; then
    if ! kubectl get service aks-istio-ingressgateway-external -n aks-istio-ingress >/dev/null 2>&1; then
      log "Enabling Azure Service Mesh external ingress gateway"
      az aks mesh enable-ingress-gateway \
        --resource-group "${RESOURCE_GROUP}" \
        --name "${CLUSTER_NAME}" \
        --ingress-gateway-type External \
        --only-show-errors \
        >/dev/null
    fi
    wait_for_service aks-istio-ingress aks-istio-ingressgateway-external
  fi

  if [[ "${ISTIO_INTERNAL_INGRESS_GATEWAY_ENABLED}" == "true" ]]; then
    if ! kubectl get service aks-istio-ingressgateway-internal -n aks-istio-ingress >/dev/null 2>&1; then
      log "Enabling Azure Service Mesh internal ingress gateway"
      az aks mesh enable-ingress-gateway \
        --resource-group "${RESOURCE_GROUP}" \
        --name "${CLUSTER_NAME}" \
        --ingress-gateway-type Internal \
        --only-show-errors \
        >/dev/null
    fi
    wait_for_service aks-istio-ingress aks-istio-ingressgateway-internal
  fi
}

ensure_keda_prometheus_auth() {
  local current_annotation=""
  local current_label=""
  local keda_prometheus_client_id=""
  local keda_prometheus_principal_id=""
  local restart_required="false"
  local federated_issuer=""
  local federated_subject=""

  wait_for_deployment "${KEDA_PROMETHEUS_OPERATOR_NAMESPACE}" "${KEDA_PROMETHEUS_OPERATOR_DEPLOYMENT_NAME}"
  wait_for_crd clustertriggerauthentications.keda.sh

  if ! az identity show --name "${KEDA_PROMETHEUS_IDENTITY_NAME}" --resource-group "${RESOURCE_GROUP}" --only-show-errors >/dev/null 2>&1; then
    log "Creating shared KEDA managed identity ${KEDA_PROMETHEUS_IDENTITY_NAME}"
    az identity create \
      --name "${KEDA_PROMETHEUS_IDENTITY_NAME}" \
      --resource-group "${RESOURCE_GROUP}" \
      --location "${LOCATION}" \
      --only-show-errors \
      >/dev/null
  else
    log "Shared KEDA managed identity ${KEDA_PROMETHEUS_IDENTITY_NAME} already exists"
  fi

  keda_prometheus_client_id="$(az identity show --name "${KEDA_PROMETHEUS_IDENTITY_NAME}" --resource-group "${RESOURCE_GROUP}" --query clientId -o tsv --only-show-errors)"
  keda_prometheus_principal_id="$(az identity show --name "${KEDA_PROMETHEUS_IDENTITY_NAME}" --resource-group "${RESOURCE_GROUP}" --query principalId -o tsv --only-show-errors)"

  if [[ -z "$(az role assignment list --assignee-object-id "${keda_prometheus_principal_id}" --scope "${monitor_workspace_id}" --query "[?roleDefinitionName=='Monitoring Data Reader'].id | [0]" -o tsv --only-show-errors)" ]]; then
    log "Granting Monitoring Data Reader on ${monitor_workspace_id} to ${KEDA_PROMETHEUS_IDENTITY_NAME}"
    az role assignment create \
      --assignee-object-id "${keda_prometheus_principal_id}" \
      --assignee-principal-type ServicePrincipal \
      --role "Monitoring Data Reader" \
      --scope "${monitor_workspace_id}" \
      --only-show-errors \
      >/dev/null
  fi

  if az identity federated-credential show \
    --name "${KEDA_PROMETHEUS_FEDERATED_CREDENTIAL_NAME}" \
    --identity-name "${KEDA_PROMETHEUS_IDENTITY_NAME}" \
    --resource-group "${RESOURCE_GROUP}" \
    --only-show-errors >/dev/null 2>&1; then
    federated_issuer="$(az identity federated-credential show --name "${KEDA_PROMETHEUS_FEDERATED_CREDENTIAL_NAME}" --identity-name "${KEDA_PROMETHEUS_IDENTITY_NAME}" --resource-group "${RESOURCE_GROUP}" --query issuer -o tsv --only-show-errors)"
    federated_subject="$(az identity federated-credential show --name "${KEDA_PROMETHEUS_FEDERATED_CREDENTIAL_NAME}" --identity-name "${KEDA_PROMETHEUS_IDENTITY_NAME}" --resource-group "${RESOURCE_GROUP}" --query subject -o tsv --only-show-errors)"

    if [[ "${federated_issuer}" != "${aks_oidc_issuer}" || "${federated_subject}" != "system:serviceaccount:${KEDA_PROMETHEUS_OPERATOR_NAMESPACE}:${KEDA_PROMETHEUS_OPERATOR_SERVICE_ACCOUNT_NAME}" ]]; then
      log "Refreshing federated credential ${KEDA_PROMETHEUS_FEDERATED_CREDENTIAL_NAME}"
      az identity federated-credential delete \
        --name "${KEDA_PROMETHEUS_FEDERATED_CREDENTIAL_NAME}" \
        --identity-name "${KEDA_PROMETHEUS_IDENTITY_NAME}" \
        --resource-group "${RESOURCE_GROUP}" \
        --only-show-errors \
        >/dev/null
    fi
  fi

  if ! az identity federated-credential show \
    --name "${KEDA_PROMETHEUS_FEDERATED_CREDENTIAL_NAME}" \
    --identity-name "${KEDA_PROMETHEUS_IDENTITY_NAME}" \
    --resource-group "${RESOURCE_GROUP}" \
    --only-show-errors >/dev/null 2>&1; then
    log "Creating federated credential ${KEDA_PROMETHEUS_FEDERATED_CREDENTIAL_NAME}"
    az identity federated-credential create \
      --name "${KEDA_PROMETHEUS_FEDERATED_CREDENTIAL_NAME}" \
      --identity-name "${KEDA_PROMETHEUS_IDENTITY_NAME}" \
      --resource-group "${RESOURCE_GROUP}" \
      --issuer "${aks_oidc_issuer}" \
      --subject "system:serviceaccount:${KEDA_PROMETHEUS_OPERATOR_NAMESPACE}:${KEDA_PROMETHEUS_OPERATOR_SERVICE_ACCOUNT_NAME}" \
      --audiences api://AzureADTokenExchange \
      --only-show-errors \
      >/dev/null
    restart_required="true"
  fi

  current_annotation="$(keda_operator_client_id_annotation)"
  if [[ "${current_annotation}" != "${keda_prometheus_client_id}" ]]; then
    log "Annotating KEDA operator service account with workload identity client id"
    kubectl annotate serviceaccount "${KEDA_PROMETHEUS_OPERATOR_SERVICE_ACCOUNT_NAME}" \
      -n "${KEDA_PROMETHEUS_OPERATOR_NAMESPACE}" \
      azure.workload.identity/client-id="${keda_prometheus_client_id}" \
      --overwrite >/dev/null
    restart_required="true"
  fi

  current_label="$(keda_operator_use_label)"
  if [[ "${current_label}" != "true" ]]; then
    log "Patching KEDA operator deployment for Azure workload identity mutation"
    kubectl patch deployment "${KEDA_PROMETHEUS_OPERATOR_DEPLOYMENT_NAME}" \
      -n "${KEDA_PROMETHEUS_OPERATOR_NAMESPACE}" \
      --type merge \
      --patch '{"spec":{"template":{"metadata":{"labels":{"azure.workload.identity/use":"true"}}}}}' >/dev/null
    restart_required="true"
  fi

  cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: keda.sh/v1alpha1
kind: ClusterTriggerAuthentication
metadata:
  name: ${KEDA_PROMETHEUS_AUTH_NAME}
spec:
  podIdentity:
    provider: azure-workload
    identityId: ${keda_prometheus_client_id}
EOF

  if ! keda_operator_has_workload_identity_env; then
    restart_required="true"
  fi

  if [[ "${restart_required}" == "true" ]]; then
    log "Restarting KEDA operator to pick up shared Prometheus workload identity"
    kubectl rollout restart deployment/${KEDA_PROMETHEUS_OPERATOR_DEPLOYMENT_NAME} -n ${KEDA_PROMETHEUS_OPERATOR_NAMESPACE} >/dev/null
  fi

  kubectl rollout status deployment/${KEDA_PROMETHEUS_OPERATOR_DEPLOYMENT_NAME} -n ${KEDA_PROMETHEUS_OPERATOR_NAMESPACE} --timeout=10m >/dev/null

  write_generated_env KEDA_PROMETHEUS_AUTH_NAME "${KEDA_PROMETHEUS_AUTH_NAME}"
  write_generated_env KEDA_PROMETHEUS_IDENTITY_NAME "${KEDA_PROMETHEUS_IDENTITY_NAME}"
  write_generated_env KEDA_PROMETHEUS_CLIENT_ID "${keda_prometheus_client_id}"
  write_generated_env QWEN_LOADTEST_KEDA_AUTH_NAME "${KEDA_PROMETHEUS_AUTH_NAME}"
}

az account set --subscription "${AZ_SUBSCRIPTION_ID}" --only-show-errors
ensure_az_extension amg

desired_istio_revision=""
aks_cluster_created="false"
if [[ "${ISTIO_SERVICE_MESH_ENABLED}" == "true" ]]; then
  desired_istio_revision="$(resolve_desired_istio_revision)"
fi

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
acr_login_server="$(az acr show --name "${ACR_NAME}" --resource-group "${RESOURCE_GROUP}" --query loginServer -o tsv --only-show-errors)"

monitor_workspace_query_endpoint="$(az monitor account show --name "${MONITOR_WORKSPACE_NAME}" --resource-group "${RESOURCE_GROUP}" --query 'properties.metrics.prometheusQueryEndpoint' -o tsv --only-show-errors 2>/dev/null || true)"
if [[ -z "${monitor_workspace_query_endpoint}" || "${monitor_workspace_query_endpoint}" == "null" ]]; then
  monitor_workspace_query_endpoint="$(az monitor account show --name "${MONITOR_WORKSPACE_NAME}" --resource-group "${RESOURCE_GROUP}" --query 'metrics.prometheusQueryEndpoint' -o tsv --only-show-errors 2>/dev/null || true)"
fi

if ! az network vnet subnet show --ids "${VNET_SUBNET_ID}" --only-show-errors >/dev/null 2>&1; then
  fail "Custom subnet ${VNET_SUBNET_ID} not found. Run 05-create-network.sh first or set VNET_SUBNET_ID to an existing subnet."
fi

create_aks_cluster() {
  local create_output cluster_state attempt
  local -a blob_driver_args=()
  local -a mesh_args=()

  if [[ "${AKS_ENABLE_BLOB_DRIVER}" == "true" ]]; then
    blob_driver_args+=(--enable-blob-driver)
  fi

  if [[ "${ISTIO_SERVICE_MESH_ENABLED}" == "true" ]]; then
    mesh_args+=(--enable-azure-service-mesh --revision "${desired_istio_revision}")
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
    "${mesh_args[@]}" \
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
  aks_cluster_created="true"
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
ensure_aks_kubeconfig

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

ensure_azure_service_mesh
ensure_keda_prometheus_auth

service_mesh_revisions_csv="$(current_service_mesh_revisions)"

write_generated_env AZ_SUBSCRIPTION_ID "${AZ_SUBSCRIPTION_ID}"
write_generated_env LOCATION "${LOCATION}"
write_generated_env RESOURCE_GROUP "${RESOURCE_GROUP}"
write_generated_env CLUSTER_NAME "${CLUSTER_NAME}"
write_generated_env ACR_NAME "${ACR_NAME}"
write_generated_env ACR_ID "$(az acr show --name "${ACR_NAME}" --resource-group "${RESOURCE_GROUP}" --query id -o tsv --only-show-errors)"
write_generated_env ACR_LOGIN_SERVER "${acr_login_server}"
write_generated_env CLUSTER_ID "${cluster_id}"
write_generated_env CLUSTER_FQDN "${aks_endpoint}"
write_generated_env AKS_OIDC_ISSUER "${aks_oidc_issuer}"
write_generated_env OIDC_ISSUER_URL "${aks_oidc_issuer}"
write_generated_env AKS_ENDPOINT "https://${aks_endpoint}"
write_generated_env CLUSTER_ENDPOINT "https://${aks_endpoint}"
write_generated_env NODE_RESOURCE_GROUP "${node_resource_group}"
write_generated_env AZURE_NODE_RESOURCE_GROUP "${node_resource_group}"
write_generated_env AKS_SUBNET_ID "${VNET_SUBNET_ID}"
write_generated_env VNET_SUBNET_ID "${VNET_SUBNET_ID}"
write_generated_env SERVICE_MESH_MODE "$([[ "${ISTIO_SERVICE_MESH_ENABLED}" == "true" ]] && printf '%s' Istio || printf '%s' Disabled)"
write_generated_env ISTIO_REVISIONS_CSV "${service_mesh_revisions_csv}"
write_generated_env SERVICE_MESH_REVISIONS_CSV "${service_mesh_revisions_csv}"
write_generated_env MONITOR_WORKSPACE_ID "${monitor_workspace_id}"
write_generated_env MONITOR_WORKSPACE_QUERY_ENDPOINT "${monitor_workspace_query_endpoint}"
write_generated_env LOG_ANALYTICS_WORKSPACE_ID "${log_analytics_workspace_id}"
write_generated_env GRAFANA_ID "${grafana_id}"
write_generated_env KUBECTL_CREDENTIALS_COMMAND "az aks get-credentials --resource-group ${RESOURCE_GROUP} --name ${CLUSTER_NAME} --overwrite-existing"

log "Cluster bootstrap completed (no cluster-autoscaler, no user node pools)"
log "AKS network mode      → Azure CNI overlay + Cilium"
log "AKS service mesh      → ${service_mesh_revisions_csv:-disabled}"
log "AKS Blob CSI Driver   → ${AKS_ENABLE_BLOB_DRIVER}"
log "AKS node subnet       → ${VNET_SUBNET_ID}"
log "AKS diagnostic logs → Log Analytics Workspace ${LOG_ANALYTICS_WORKSPACE_NAME}"
log "KEDA Prometheus auth  → ${KEDA_PROMETHEUS_AUTH_NAME}"
log "Next step: run 01-environment/shell/15-deploy-karpenter.sh to deploy Karpenter"
kubectl get nodes -L agentpool
