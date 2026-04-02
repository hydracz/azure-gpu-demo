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
source "${SCRIPT_DIR}/common.sh"

load_env
ensure_tooling

GPU_NODE_IMAGE_FAMILY="${GPU_NODE_IMAGE_FAMILY:-Ubuntu2404}"
GPU_OS_DISK_SIZE_GB="${GPU_OS_DISK_SIZE_GB:-1024}"
GPU_ZONES="${GPU_ZONES:-${LOCATION}-1}"

[[ "${GPU_OS_DISK_SIZE_GB}" =~ ^[0-9]+$ ]] || fail "GPU_OS_DISK_SIZE_GB must be an integer, got: ${GPU_OS_DISK_SIZE_GB}"
(( GPU_OS_DISK_SIZE_GB >= 30 )) || fail "GPU_OS_DISK_SIZE_GB must be at least 30 GB, got: ${GPU_OS_DISK_SIZE_GB}"

# Helm Chart 位于项目根目录 charts/
KARPENTER_CHART_DIR="${ROOT_DIR}/charts"
[[ -d "${KARPENTER_CHART_DIR}/karpenter" ]] || fail "Karpenter Helm Chart not found at ${KARPENTER_CHART_DIR}/karpenter. See README.md for chart setup instructions."

require_env \
  AZ_SUBSCRIPTION_ID RESOURCE_GROUP CLUSTER_NAME LOCATION \
  KARPENTER_NAMESPACE KARPENTER_SERVICE_ACCOUNT KARPENTER_IDENTITY_NAME \
  KARPENTER_IMAGE_REPO KARPENTER_IMAGE_TAG \
  GPU_SKU_NAME GPU_TYPE INSTALL_GPU_DRIVERS \
  CONSOLIDATE_AFTER SPOT_MAX_PRICE \
  GPU_ZONES VNET_SUBNET_ID

az account set --subscription "${AZ_SUBSCRIPTION_ID}" --only-show-errors

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
[[ "${vnet_subnet_id}" == "${VNET_SUBNET_ID}" ]] || fail "AKS is using subnet ${vnet_subnet_id}, but configured VNET_SUBNET_ID is ${VNET_SUBNET_ID}"

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
write_generated_env VNET_SUBNET_ID "${vnet_subnet_id}"
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
ephemeral_os_disk_min_size_gb="$((GPU_OS_DISK_SIZE_GB - 1))"

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

  existing="$(az role assignment list \
    --assignee "${principal}" \
    --role "${role}" \
    --scope "${scope}" \
    --query "length(@)" \
    -o tsv \
    --only-show-errors 2>/dev/null || echo 0)"

  if [[ "${existing}" == "0" ]]; then
    log "Assigning role '${role}' on scope $(basename "${scope}")"
    az role assignment create \
      --assignee-object-id "${identity_principal_id}" \
      --assignee-principal-type ServicePrincipal \
      --role "${role}" \
      --scope "${scope}" \
      --only-show-errors \
      >/dev/null
  else
    log "Role '${role}' already assigned on $(basename "${scope}")"
  fi
}

# Karpenter 需要在 node resource group 创建/删除 VM、VMSS、NIC 等
assign_role_if_missing "Virtual Machine Contributor"     "${node_rg_id}" "${identity_principal_id}"
assign_role_if_missing "Network Contributor"             "${node_rg_id}" "${identity_principal_id}"
assign_role_if_missing "Managed Identity Operator"       "${node_rg_id}" "${identity_principal_id}"
# 自定义 VNet/Subnet 场景下, 还需要对 subnet 本身授予 join / IP 管理权限
assign_role_if_missing "Network Contributor"             "${vnet_subnet_id}" "${identity_principal_id}"

# Karpenter 需要把 AKS agentpool 的 UAMI 绑定到新建 VM 上
while IFS= read -r node_identity_id; do
  [[ -n "${node_identity_id}" ]] || continue
  assign_role_if_missing "Managed Identity Operator" "${node_identity_id}" "${identity_principal_id}"
done < <(python3 - <<'PY' "${NODE_IDENTITIES}"
import sys

for item in sys.argv[1].split(','):
    item = item.strip()
    if item:
        print(item)
PY
)

# 允许 Karpenter 从 ACR 拉取镜像
acr_id="$(az acr show --name "${ACR_NAME}" --resource-group "${RESOURCE_GROUP}" --query id -o tsv --only-show-errors)"
assign_role_if_missing "AcrPull" "${acr_id}" "${identity_principal_id}"

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
  log "Federated credential ${fed_cred_name} already exists"
fi

# ── 4. Helm 安装 Karpenter ────────────────────────────────────────
log "Installing karpenter-crd from ${KARPENTER_CHART_DIR}/karpenter-crd"
helm upgrade --install karpenter-crd \
  "${KARPENTER_CHART_DIR}/karpenter-crd" \
  --namespace "${KARPENTER_NAMESPACE}" \
  --create-namespace \
  --wait

log "Installing karpenter from ${KARPENTER_CHART_DIR}/karpenter"
log "Using Karpenter controller image ${KARPENTER_IMAGE_REPO}:${KARPENTER_IMAGE_TAG}"
helm upgrade --install karpenter \
  "${KARPENTER_CHART_DIR}/karpenter" \
  --namespace "${KARPENTER_NAMESPACE}" \
  --reset-values \
  -f "${tmp_values_file}" \
  --set "controller.image.repository=${KARPENTER_IMAGE_REPO}" \
  --set "controller.image.tag=${KARPENTER_IMAGE_TAG}" \
  --set "controller.image.digest=" \
  --set "settings.clusterName=${CLUSTER_NAME}" \
  --set "settings.clusterEndpoint=${AKS_ENDPOINT}" \
  --set "replicas=1" \
  --wait \
  --timeout 5m

log "Waiting for Karpenter controller to be ready"
kubectl -n "${KARPENTER_NAMESPACE}" rollout status deploy/karpenter --timeout=5m

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
        workload: gpu-test
        gputype: ${GPU_TYPE}
        spot_pool: "yes"
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
        - key: karpenter.azure.com/sku-storage-ephemeralos-maxsize
          operator: Gt
          values: ["${ephemeral_os_disk_min_size_gb}"]
        - key: node.kubernetes.io/instance-type
          operator: In
          values: ["${GPU_SKU_NAME}"]
      taints:
        - key: workload
          value: gpu-test
          effect: NoSchedule
      nodeClassRef:
        group: karpenter.azure.com
        kind: AKSNodeClass
        name: gpu
  disruption:
    consolidationPolicy: WhenEmpty
    consolidateAfter: ${CONSOLIDATE_AFTER}
EOF

# NodePool — On-demand GPU (低权重, Spot 不可用时回退)
cat <<EOF | kubectl apply -f -
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: gpu-ondemand-pool
  annotations:
    kubernetes.io/description: "On-demand GPU pool - fallback when Spot unavailable"
spec:
  weight: 10
  template:
    metadata:
      labels:
        workload: gpu-test
        gputype: ${GPU_TYPE}
        spot_pool: "no"
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
        - key: karpenter.azure.com/sku-storage-ephemeralos-maxsize
          operator: Gt
          values: ["${ephemeral_os_disk_min_size_gb}"]
        - key: node.kubernetes.io/instance-type
          operator: In
          values: ["${GPU_SKU_NAME}"]
      taints:
        - key: workload
          value: gpu-test
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
log "  GPU OS disk size : ${GPU_OS_DISK_SIZE_GB} GiB (prefer ephemeral NVMe)"
log "  installGPUDrivers: ${INSTALL_GPU_DRIVERS}"
log "  NodePools        : gpu-spot-pool (weight=100), gpu-ondemand-pool (weight=10)"
log "  AKSNodeClass     : gpu (${GPU_NODE_IMAGE_FAMILY}, subnet=${vnet_subnet_id}, osDisk=${GPU_OS_DISK_SIZE_GB}GiB, installGPUDrivers=${INSTALL_GPU_DRIVERS})"
log ""
log "⚠ NOTE: Spot quota may be < 128 vCPU. If gpu-spot-pool cannot provision,"
log "  Karpenter will fallback to gpu-ondemand-pool (on-demand)."
kubectl get nodepools,aksnodeclasses
