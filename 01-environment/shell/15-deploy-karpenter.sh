#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 15-deploy-karpenter.sh  —  部署 Karpenter (自编译版本, GPU 场景) 到 AKS
#
# 核心特点:
#   1. NodePool 通过 karpenter.azure.com/sku-name 精确指定 GPU SKU
#   2. AKSNodeClass 设置 installGPUDrivers: false 跳过 GPU 驱动安装
#   3. 不设置 NodePool GPU 上限, 避免 SKU 元数据与实际 GPU 数不一致导致误判
#   4. Azure CNI overlay + Cilium 场景下, 自定义 subnet 作为节点子网
#   5. Spot 配额不足场景: spot-pool 可能无法创建任何节点, 由 on-demand-pool 兜底
# ---------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../../common.sh"

load_env
ensure_tooling

: "${SYSTEM_POOL_NAME:=sysd4}"
: "${KARPENTER_NAMESPACE:=kube-system}"
: "${KARPENTER_SERVICE_ACCOUNT:=karpenter-sa}"
: "${KARPENTER_IMAGE_REPO:=quay.io/hydracz/karpenter-controller}"
: "${KARPENTER_IMAGE_REPOSITORY:=${KARPENTER_IMAGE_REPO}}"
: "${KARPENTER_IMAGE_TAG:=v20260323-dev}"
: "${GPU_SKU_NAME:=Standard_NC128lds_xl_RTXPRO6000BSE_v6}"
GPU_NODE_IMAGE_FAMILY="${GPU_NODE_IMAGE_FAMILY:-Ubuntu2404}"
GPU_OS_DISK_SIZE_GB="${GPU_OS_DISK_SIZE_GB:-1024}"
GPU_ZONES="${GPU_ZONES:-${LOCATION}-1}"
INSTALL_GPU_DRIVERS="${INSTALL_GPU_DRIVERS:-false}"
CONSOLIDATE_AFTER="${CONSOLIDATE_AFTER:-10m}"
SPOT_MAX_PRICE="${SPOT_MAX_PRICE:--1}"
GPU_NODE_CLASS="${GPU_NODE_CLASS:-${GPU_NODE_WORKLOAD_LABEL:-gpu}}"
GPU_NODE_SCHEDULING_KEY="${GPU_NODE_SCHEDULING_KEY:-scheduling.azure-gpu-demo/dedicated}"
ROLE_ASSIGNMENT_MAX_RETRIES="${ROLE_ASSIGNMENT_MAX_RETRIES:-6}"
ROLE_ASSIGNMENT_RETRY_SECONDS="${ROLE_ASSIGNMENT_RETRY_SECONDS:-10}"

[[ "${GPU_OS_DISK_SIZE_GB}" =~ ^[0-9]+$ ]] || fail "GPU_OS_DISK_SIZE_GB must be an integer, got: ${GPU_OS_DISK_SIZE_GB}"
(( GPU_OS_DISK_SIZE_GB >= 30 )) || fail "GPU_OS_DISK_SIZE_GB must be at least 30 GB, got: ${GPU_OS_DISK_SIZE_GB}"
[[ "${ROLE_ASSIGNMENT_MAX_RETRIES}" =~ ^[0-9]+$ ]] || fail "ROLE_ASSIGNMENT_MAX_RETRIES must be an integer, got: ${ROLE_ASSIGNMENT_MAX_RETRIES}"
[[ "${ROLE_ASSIGNMENT_RETRY_SECONDS}" =~ ^[0-9]+$ ]] || fail "ROLE_ASSIGNMENT_RETRY_SECONDS must be an integer, got: ${ROLE_ASSIGNMENT_RETRY_SECONDS}"

# Helm Chart 位于项目根目录 charts/
KARPENTER_CHART_DIR="${ROOT_DIR}/01-environment/charts"
[[ -d "${KARPENTER_CHART_DIR}/karpenter" ]] || fail "Karpenter Helm Chart not found at ${KARPENTER_CHART_DIR}/karpenter. See README.md for chart setup instructions."

require_env \
  AZ_SUBSCRIPTION_ID RESOURCE_GROUP CLUSTER_NAME LOCATION EXISTING_ACR_ID \
  KARPENTER_NAMESPACE KARPENTER_SERVICE_ACCOUNT KARPENTER_IDENTITY_NAME \
  KARPENTER_IMAGE_TAG KARPENTER_TARGET_IMAGE_REPOSITORY \
  GPU_SKU_NAME INSTALL_GPU_DRIVERS \
  CONSOLIDATE_AFTER SPOT_MAX_PRICE \
  GPU_ZONES EXISTING_VNET_SUBNET_ID GPU_NODE_CLASS

az account set --subscription "${AZ_SUBSCRIPTION_ID}" --only-show-errors
export AZURE_SUBSCRIPTION_ID="${AZ_SUBSCRIPTION_ID}"

# ── 加载 .generated.env 中集群信息 ─────────────────────────────────
require_env AKS_OIDC_ISSUER AKS_ENDPOINT NODE_RESOURCE_GROUP

az aks get-credentials \
  --resource-group "${RESOURCE_GROUP}" \
  --name "${CLUSTER_NAME}" \
  --overwrite-existing \
  --only-show-errors \
  >/dev/null

aks_json="$(az aks show \
  --resource-group "${RESOURCE_GROUP}" \
  --name "${CLUSTER_NAME}" \
  --only-show-errors \
  -o json)"

# ── 1. 创建 Managed Identity ──────────────────────────────────────
if ! az identity show --name "${KARPENTER_IDENTITY_NAME}" --resource-group "${RESOURCE_GROUP}" --only-show-errors >/dev/null 2>&1; then
  log "Creating Managed Identity ${KARPENTER_IDENTITY_NAME}"
  az identity create \
    --name "${KARPENTER_IDENTITY_NAME}" \
    --resource-group "${RESOURCE_GROUP}" \
    --location "${LOCATION}" \
    --only-show-errors \
    >/dev/null
else
  log "Managed Identity ${KARPENTER_IDENTITY_NAME} already exists"
fi

identity_client_id="$(az identity show --name "${KARPENTER_IDENTITY_NAME}" --resource-group "${RESOURCE_GROUP}" --query clientId -o tsv --only-show-errors)"
identity_principal_id="$(az identity show --name "${KARPENTER_IDENTITY_NAME}" --resource-group "${RESOURCE_GROUP}" --query principalId -o tsv --only-show-errors)"

write_generated_env KARPENTER_CLIENT_ID "${identity_client_id}"

bootstrap_secret_name="$(kubectl get secrets -n kube-system -o go-template='{{range .items}}{{if eq .type "bootstrap.kubernetes.io/token"}}{{.metadata.name}}{{"\n"}}{{end}}{{end}}' | head -n1)"
[[ -n "${bootstrap_secret_name}" ]] || fail "No bootstrap token secret found in kube-system"

bootstrap_token_id="$(kubectl get secret -n kube-system "${bootstrap_secret_name}" -o jsonpath='{.data.token-id}' | base64 -d)"
bootstrap_token_secret="$(kubectl get secret -n kube-system "${bootstrap_secret_name}" -o jsonpath='{.data.token-secret}' | base64 -d)"
[[ -n "${bootstrap_token_id}" && -n "${bootstrap_token_secret}" ]] || fail "Bootstrap token secret ${bootstrap_secret_name} is missing token-id or token-secret"
kubelet_bootstrap_token="${bootstrap_token_id}.${bootstrap_token_secret}"

system_vmss_name="$(az vmss list \
  --resource-group "${NODE_RESOURCE_GROUP}" \
  --query "[?starts_with(name, 'aks-${SYSTEM_POOL_NAME}-')].name | [0]" \
  -o tsv \
  --only-show-errors)"
[[ -n "${system_vmss_name}" ]] || fail "Unable to determine system nodepool VMSS name in ${NODE_RESOURCE_GROUP}"

vnet_subnet_id="$(az vmss show \
  --resource-group "${NODE_RESOURCE_GROUP}" \
  --name "${system_vmss_name}" \
  --query 'virtualMachineProfile.networkProfile.networkInterfaceConfigurations[0].ipConfigurations[0].subnet.id' \
  -o tsv \
  --only-show-errors)"
[[ -n "${vnet_subnet_id}" ]] || fail "Unable to determine vnet subnet id from VMSS ${system_vmss_name}"
[[ "${vnet_subnet_id}" == "${EXISTING_VNET_SUBNET_ID}" ]] || fail "AKS is using subnet ${vnet_subnet_id}, but configured EXISTING_VNET_SUBNET_ID is ${EXISTING_VNET_SUBNET_ID}"
vnet_id="$(az network vnet show --ids "${vnet_subnet_id%/subnets/*}" --query id -o tsv --only-show-errors)"
[[ -n "${vnet_id}" ]] || fail "Unable to determine parent vnet id from subnet ${vnet_subnet_id}"
gpu_node_scheduling_key="${GPU_NODE_SCHEDULING_KEY}"

ssh_public_key="$(python3 - <<'PY' "${aks_json}"
import json
import sys

payload = json.loads(sys.argv[1])
keys = (((payload.get("linuxProfile") or {}).get("ssh") or {}).get("publicKeys") or [])
if keys:
    print(keys[0].get("keyData", ""))
PY
)"
[[ -n "${ssh_public_key}" ]] || fail "Unable to determine SSH public key from AKS linuxProfile"

network_plugin="$(python3 - <<'PY' "${aks_json}"
import json
import sys

payload = json.loads(sys.argv[1])
print(((payload.get("networkProfile") or {}).get("networkPlugin")) or "")
PY
)"
network_plugin_mode="$(python3 - <<'PY' "${aks_json}"
import json
import sys

payload = json.loads(sys.argv[1])
print(((payload.get("networkProfile") or {}).get("networkPluginMode")) or "")
PY
)"
network_policy="$(python3 - <<'PY' "${aks_json}"
import json
import sys

payload = json.loads(sys.argv[1])
print(((payload.get("networkProfile") or {}).get("networkPolicy")) or "")
PY
)"
kubelet_identity_client_id="$(python3 - <<'PY' "${aks_json}"
import json
import sys

payload = json.loads(sys.argv[1])
profile = (payload.get("identityProfile") or {}).get("kubeletidentity") or {}
print(profile.get("clientId", ""))
PY
)"
node_identities="$(python3 - <<'PY' "${aks_json}"
import json
import sys

payload = json.loads(sys.argv[1])
profile = (payload.get("identityProfile") or {}).get("kubeletidentity") or {}
print(profile.get("resourceId", ""))
PY
)"

write_generated_env KUBELET_BOOTSTRAP_TOKEN "${kubelet_bootstrap_token}"
write_generated_env EXISTING_VNET_SUBNET_ID "${vnet_subnet_id}"
write_generated_env SSH_PUBLIC_KEY "${ssh_public_key}"
write_generated_env NETWORK_PLUGIN "${network_plugin}"
write_generated_env NETWORK_PLUGIN_MODE "${network_plugin_mode}"
write_generated_env NETWORK_POLICY "${network_policy}"
write_generated_env KUBELET_IDENTITY_CLIENT_ID "${kubelet_identity_client_id}"
write_generated_env NODE_IDENTITIES "${node_identities}"
write_generated_env AZURE_NODE_RESOURCE_GROUP "${NODE_RESOURCE_GROUP}"

gpu_zones_yaml="$(python3 - <<'PY' "${GPU_ZONES}"
import sys

zones = [zone.strip() for zone in sys.argv[1].split(',') if zone.strip()]
if not zones:
    raise SystemExit("GPU_ZONES must contain at least one availability zone")

for zone in zones:
    print(f"            - {zone}")
PY
)"

tmp_values_file="$(mktemp)"
cleanup() {
  rm -f "${tmp_values_file}"
}
trap cleanup EXIT

cat >"${tmp_values_file}" <<EOF
serviceAccount:
  name: ${KARPENTER_SERVICE_ACCOUNT}
  annotations:
    azure.workload.identity/client-id: "${identity_client_id}"
podLabels:
  azure.workload.identity/use: "true"
controller:
  env:
    - name: KUBELET_BOOTSTRAP_TOKEN
      value: "${kubelet_bootstrap_token}"
    - name: SSH_PUBLIC_KEY
      value: "${ssh_public_key}"
    - name: VNET_SUBNET_ID
      value: "${vnet_subnet_id}"
    - name: AZURE_NODE_RESOURCE_GROUP
      value: "${NODE_RESOURCE_GROUP}"
    - name: AZURE_SUBSCRIPTION_ID
      value: "${AZ_SUBSCRIPTION_ID}"
    - name: LOCATION
      value: "${LOCATION}"
    - name: NETWORK_PLUGIN
      value: "${network_plugin}"
    - name: NETWORK_PLUGIN_MODE
      value: "${network_plugin_mode}"
    - name: NETWORK_POLICY
      value: "${network_policy}"
    - name: KUBELET_IDENTITY_CLIENT_ID
      value: "${kubelet_identity_client_id}"
    - name: NODE_IDENTITIES
      value: "${node_identities}"
EOF

# ── 2. 分配 RBAC 权限 ─────────────────────────────────────────────
node_rg_id="/subscriptions/${AZ_SUBSCRIPTION_ID}/resourceGroups/${NODE_RESOURCE_GROUP}"

assign_role_if_missing() {
  local role="$1"
  local scope="$2"
  local principal="$3"
  local existing attempt create_output scope_name

  scope_name="$(basename "${scope}")"

  role_assignment_exists() {
    local current_role="$1"
    local current_scope="$2"
    local current_principal="$3"

    az role assignment list \
      --assignee "${current_principal}" \
      --role "${current_role}" \
      --scope "${current_scope}" \
      --query "length(@)" \
      -o tsv \
      --only-show-errors 2>/dev/null
  }

  existing="$(role_assignment_exists "${role}" "${scope}" "${principal}" || echo 0)"

  if [[ "${existing}" != "0" ]]; then
    log "Role '${role}' already assigned on ${scope_name}"
    return 0
  fi

  for attempt in $(seq 1 "${ROLE_ASSIGNMENT_MAX_RETRIES}"); do
    log "Ensuring role '${role}' on ${scope_name} (attempt ${attempt}/${ROLE_ASSIGNMENT_MAX_RETRIES})"

    if create_output="$(az role assignment create \
      --assignee-object-id "${identity_principal_id}" \
      --assignee-principal-type ServicePrincipal \
      --role "${role}" \
      --scope "${scope}" \
      --only-show-errors \
      -o none 2>&1)"; then
      log "Assigned role '${role}' on ${scope_name}"
      return 0
    fi

    if [[ "${create_output}" == *"RoleAssignmentExists"* ]]; then
      log "Role '${role}' already assigned on ${scope_name}"
      return 0
    fi

    existing="$(role_assignment_exists "${role}" "${scope}" "${principal}" || echo 0)"
    if [[ "${existing}" != "0" ]]; then
      log "Role '${role}' already assigned on ${scope_name}"
      return 0
    fi

    if [[ "${create_output}" == *"PrincipalNotFound"* || "${create_output}" == *"does not exist in the directory"* || "${create_output}" == *"could not be found"* || "${create_output}" == *"Insufficient privileges to complete the operation"* ]]; then
      if (( attempt < ROLE_ASSIGNMENT_MAX_RETRIES )); then
        warn "Role assignment for '${role}' on ${scope_name} is waiting for directory propagation; retrying in ${ROLE_ASSIGNMENT_RETRY_SECONDS}s"
        sleep "${ROLE_ASSIGNMENT_RETRY_SECONDS}"
        continue
      fi
    fi

    fail "Failed to assign role '${role}' on ${scope_name}: ${create_output}"
  done
}

# Karpenter 需要在 node resource group 创建/删除 VM、VMSS、NIC 等
assign_role_if_missing "Virtual Machine Contributor"     "${node_rg_id}" "${identity_principal_id}"
assign_role_if_missing "Network Contributor"             "${node_rg_id}" "${identity_principal_id}"
assign_role_if_missing "Managed Identity Operator"       "${node_rg_id}" "${identity_principal_id}"
# 自定义 VNet/Subnet 场景下, Karpenter 既要读取父级 VNet, 也需要在 subnet 上做 join / IP 管理
assign_role_if_missing "Reader"                          "${vnet_id}" "${identity_principal_id}"
assign_role_if_missing "Network Contributor"             "${vnet_subnet_id}" "${identity_principal_id}"

# Karpenter 需要把 AKS agentpool 的 UAMI 绑定到新建 VM 上
while IFS= read -r node_identity_id; do
  [[ -n "${node_identity_id}" ]] || continue
  assign_role_if_missing "Managed Identity Operator" "${node_identity_id}" "${identity_principal_id}"
done < <(python3 - <<'PY' "${NODE_IDENTITIES:-}"
import sys

for item in sys.argv[1].split(','):
    item = item.strip()
    if item:
        print(item)
PY
)

# 允许 Karpenter 从预准备 ACR 拉取镜像
assign_role_if_missing "AcrPull" "${EXISTING_ACR_ID}" "${identity_principal_id}"

# ── 3. Federated Identity Credential ──────────────────────────────
fed_cred_name="${KARPENTER_IDENTITY_NAME}-fed-cred"
subject="system:serviceaccount:${KARPENTER_NAMESPACE}:${KARPENTER_SERVICE_ACCOUNT}"

if ! az identity federated-credential show \
    --name "${fed_cred_name}" \
    --identity-name "${KARPENTER_IDENTITY_NAME}" \
    --resource-group "${RESOURCE_GROUP}" \
    --only-show-errors >/dev/null 2>&1; then
  log "Creating federated credential for ${subject}"
  az identity federated-credential create \
    --name "${fed_cred_name}" \
    --identity-name "${KARPENTER_IDENTITY_NAME}" \
    --resource-group "${RESOURCE_GROUP}" \
    --issuer "${AKS_OIDC_ISSUER}" \
    --subject "${subject}" \
    --audiences "api://AzureADTokenExchange" \
    --only-show-errors \
    >/dev/null
else
  log "Updating federated credential ${fed_cred_name} to match current AKS OIDC issuer"
  az identity federated-credential update \
    --name "${fed_cred_name}" \
    --identity-name "${KARPENTER_IDENTITY_NAME}" \
    --resource-group "${RESOURCE_GROUP}" \
    --issuer "${AKS_OIDC_ISSUER}" \
    --subject "${subject}" \
    --audiences "api://AzureADTokenExchange" \
    --only-show-errors \
    >/dev/null
fi

# ── 4. Helm 安装 Karpenter ────────────────────────────────────────
log "Installing karpenter-crd from ${KARPENTER_CHART_DIR}/karpenter-crd"
helm upgrade --install karpenter-crd \
  "${KARPENTER_CHART_DIR}/karpenter-crd" \
  --namespace "${KARPENTER_NAMESPACE}" \
  --create-namespace \
  --wait

log "Installing karpenter from ${KARPENTER_CHART_DIR}/karpenter"
log "Using mirrored Karpenter controller image ${KARPENTER_TARGET_IMAGE_REPOSITORY}:${KARPENTER_IMAGE_TAG}"
helm upgrade --install karpenter \
  "${KARPENTER_CHART_DIR}/karpenter" \
  --namespace "${KARPENTER_NAMESPACE}" \
  --reset-values \
  -f "${tmp_values_file}" \
  --set "serviceMonitor.enabled=true" \
  --set "controller.image.repository=${KARPENTER_TARGET_IMAGE_REPOSITORY}" \
  --set "controller.image.tag=${KARPENTER_IMAGE_TAG}" \
  --set "controller.image.digest=" \
  --set "settings.clusterName=${CLUSTER_NAME}" \
  --set "settings.clusterEndpoint=${AKS_ENDPOINT}" \
  --set "replicas=1" \
  --wait \
  --timeout 5m

log "Waiting for Karpenter controller to be ready"
kubectl -n "${KARPENTER_NAMESPACE}" rollout status deploy/karpenter --timeout=5m

log "Applying Azure Monitor ServiceMonitor mirror for Karpenter"
KARPENTER_NAMESPACE="${KARPENTER_NAMESPACE}" \
  bash "${ROOT_DIR}/01-environment/scripts/apply-azmonitor-servicemonitors.sh"

# ── 5. 部署 AKSNodeClass + NodePool (GPU 场景) ───────────────────
log "Applying AKSNodeClass and NodePool manifests for GPU (${GPU_SKU_NAME})"

# AKSNodeClass — installGPUDrivers: false 跳过 GPU 驱动安装
cat <<EOF | kubectl apply -f -
apiVersion: karpenter.azure.com/v1beta1
kind: AKSNodeClass
metadata:
  name: gpu
  annotations:
    kubernetes.io/description: "GPU AKSNodeClass - overlay node subnet, 1TiB ephemeral OS disk, skip GPU driver installation"
spec:
  imageFamily: ${GPU_NODE_IMAGE_FAMILY}
  vnetSubnetID: ${vnet_subnet_id}
  osDiskSizeGB: ${GPU_OS_DISK_SIZE_GB}
  installGPUDrivers: ${INSTALL_GPU_DRIVERS}
EOF

# NodePool — Spot GPU (高权重, 优先使用)
# 不设置 spec.limits，避免 Azure SKU 元数据中的 GPU 数与实际可用 GPU 数不一致时
# 被 Karpenter 提前判定为 "all available instance types exceed limits"
cat <<EOF | kubectl apply -f -
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: gpu-spot-pool
  annotations:
    kubernetes.io/description: "Spot GPU pool - may fail if Spot quota < 128 vCPU"
spec:
  weight: 100
  template:
    metadata:
      labels:
        ${gpu_node_scheduling_key}: ${GPU_NODE_CLASS}
      annotations:
        karpenter.azure.com/spot-max-price: "${SPOT_MAX_PRICE}"
    spec:
      requirements:
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["spot"]
        - key: topology.kubernetes.io/zone
          operator: In
          values:
${gpu_zones_yaml}
        - key: kubernetes.io/arch
          operator: In
          values: ["amd64"]
        - key: node.kubernetes.io/instance-type
          operator: In
          values: ["${GPU_SKU_NAME}"]
      taints:
        - key: ${gpu_node_scheduling_key}
          value: ${GPU_NODE_CLASS}
          effect: NoSchedule
      nodeClassRef:
        group: karpenter.azure.com
        kind: AKSNodeClass
        name: gpu
  disruption:
    consolidationPolicy: WhenEmpty
    consolidateAfter: ${CONSOLIDATE_AFTER}
EOF

# NodePool — On-demand GPU（统一承担 seed + fallback，并允许空闲时缩到 0）
cat <<EOF | kubectl apply -f -
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: gpu-ondemand-pool
  annotations:
    kubernetes.io/description: "On-demand GPU pool - seed and fallback capacity, scale from zero when idle"
spec:
  weight: 50
  template:
    metadata:
      labels:
        ${gpu_node_scheduling_key}: ${GPU_NODE_CLASS}
    spec:
      requirements:
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["on-demand"]
        - key: topology.kubernetes.io/zone
          operator: In
          values:
${gpu_zones_yaml}
        - key: kubernetes.io/arch
          operator: In
          values: ["amd64"]
        - key: node.kubernetes.io/instance-type
          operator: In
          values: ["${GPU_SKU_NAME}"]
      taints:
        - key: ${gpu_node_scheduling_key}
          value: ${GPU_NODE_CLASS}
          effect: NoSchedule
      nodeClassRef:
        group: karpenter.azure.com
        kind: AKSNodeClass
        name: gpu
  disruption:
    consolidationPolicy: WhenEmpty
    consolidateAfter: ${CONSOLIDATE_AFTER}
EOF

log "Karpenter GPU deployment completed"
log "  Controller image : ${KARPENTER_IMAGE_REPO}:${KARPENTER_IMAGE_TAG}"
log "  GPU SKU          : ${GPU_SKU_NAME}"
log "  Custom subnet    : ${vnet_subnet_id}"
log "  GPU OS disk size : ${GPU_OS_DISK_SIZE_GB} GiB"
log "  installGPUDrivers: ${INSTALL_GPU_DRIVERS}"
log "  NodePools        : gpu-spot-pool (weight=100, elastic preferred), gpu-ondemand-pool (weight=50, baseline + fallback)"
log "  Scheduling key   : ${gpu_node_scheduling_key}=${GPU_NODE_CLASS}"
log "  AKSNodeClass     : gpu (${GPU_NODE_IMAGE_FAMILY}, subnet=${vnet_subnet_id}, osDisk=${GPU_OS_DISK_SIZE_GB}GiB, installGPUDrivers=${INSTALL_GPU_DRIVERS})"
log ""
log "⚠ NOTE: Spot quota may be < 128 vCPU. If gpu-spot-pool cannot provision,"
log "  Karpenter will fallback to gpu-ondemand-pool, which keeps baseline capacity and also scales from zero when idle."
kubectl get nodepools,aksnodeclasses
