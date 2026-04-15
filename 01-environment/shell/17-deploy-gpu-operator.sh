#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 17-deploy-gpu-operator.sh  —  部署 NVIDIA GPU Operator (driver disabled)
#                                + 定制 NVIDIADriver CR
#
# 因为使用 installGPUDrivers=false 跳过了 AKS 默认 GPU 驱动安装,
# 需要通过 GPU Operator 管理 GPU 驱动生命周期:
#   1. 安装 GPU Operator (Helm), driver.enabled=false
#   2. 部署 NVIDIADriver CR, 使用定制的 vGPU 容器化驱动
#
# GPU Operator 仍会安装以下组件 (driver 除外):
#   - nvidia-device-plugin (上报 nvidia.com/gpu 资源)
#   - nvidia-container-toolkit (配置 containerd runtime)
#   - dcgm-exporter (GPU 监控指标)
#   - node-feature-discovery (GPU 硬件标签)
# ---------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../../common.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../scripts/prepared-image-env.sh"

load_env
ensure_tooling

GPU_OPERATOR_CHART_DIR="${ROOT_DIR}/01-environment/charts/gpu-operator"
[[ -d "${GPU_OPERATOR_CHART_DIR}" ]] || fail "GPU Operator Helm Chart not found at ${GPU_OPERATOR_CHART_DIR}. See README.md for chart setup instructions."

GPU_OPERATOR_NAMESPACE="${GPU_OPERATOR_NAMESPACE:-gpu-operator}"
GPU_DRIVER_CR_NAME="${GPU_DRIVER_CR_NAME:-rtxpro6000-azure}"
GPU_DRIVER_NODE_SELECTOR_KEY="${GPU_DRIVER_NODE_SELECTOR_KEY:-karpenter.azure.com/sku-gpu-name}"
GPU_DRIVER_SOURCE_REPOSITORY="${GPU_DRIVER_SOURCE_REPOSITORY:-docker.io/yingeli}"
GPU_DRIVER_IMAGE="${GPU_DRIVER_IMAGE:-driver}"
GPU_DRIVER_VERSION="${GPU_DRIVER_VERSION:-580.105.08}"
GPU_DRIVER_REQUIRE_MATCHING_NODES="${GPU_DRIVER_REQUIRE_MATCHING_NODES:-false}"
GPU_OPERATOR_DEP_CHART_DIR="${GPU_OPERATOR_CHART_DIR}/charts/node-feature-discovery"
GPU_OPERATOR_DEP_CHART_PACKAGE="${GPU_OPERATOR_CHART_DIR}/charts/node-feature-discovery-chart-0.18.2.tgz"

ensure_gpu_operator_chart_deps() {
  if [[ -d "${GPU_OPERATOR_DEP_CHART_DIR}" || -f "${GPU_OPERATOR_DEP_CHART_PACKAGE}" ]]; then
    return
  fi

  fail "Missing vendored GPU Operator dependency under ${GPU_OPERATOR_CHART_DIR}/charts. This script no longer runs helm dependency update; vendor the chart dependencies first."
}

ensure_gpu_operator_controller() {
  if kubectl -n "${GPU_OPERATOR_NAMESPACE}" get deploy/gpu-operator >/dev/null 2>&1; then
    log "Upgrading NVIDIA GPU Operator from ${GPU_OPERATOR_CHART_DIR}"
  else
    log "Installing NVIDIA GPU Operator from ${GPU_OPERATOR_CHART_DIR}"
  fi
  log "GPU Operator mirrored repositories:"
  log "  operator repo      : ${GPU_OPERATOR_MIRROR_NVIDIA_REPOSITORY}"
  log "  cloud-native repo  : ${GPU_OPERATOR_MIRROR_NVIDIA_CLOUD_NATIVE_REPOSITORY}"
  log "  k8s repo           : ${GPU_OPERATOR_MIRROR_NVIDIA_K8S_REPOSITORY}"
  log "  nfd repo           : ${GPU_OPERATOR_MIRROR_NFD_REPOSITORY}"
  log "  driver repo        : ${GPU_DRIVER_TARGET_REPOSITORY}"
  log "  driver.enabled=false (will use NVIDIADriver CR instead)"
  log "  dcgmExporter.serviceMonitor.enabled=true"

  ensure_gpu_operator_chart_deps

  local tmp_values_file
  tmp_values_file="$(mktemp)"
  write_gpu_operator_mirror_values_file "${tmp_values_file}"

  helm upgrade --install gpu-operator \
    "${GPU_OPERATOR_CHART_DIR}" \
    --namespace "${GPU_OPERATOR_NAMESPACE}" \
    --create-namespace \
    -f "${tmp_values_file}" \
    --set driver.enabled=false \
    --set driver.nvidiaDriverCRD.enabled=true \
    --set driver.nvidiaDriverCRD.deployDefaultCR=false \
    --set toolkit.enabled=true \
    --set devicePlugin.enabled=true \
    --set dcgmExporter.enabled=true \
    --set dcgmExporter.serviceMonitor.enabled=true \
    --set "daemonsets.tolerations[0].key=nvidia.com/gpu" \
    --set "daemonsets.tolerations[0].operator=Exists" \
    --set "daemonsets.tolerations[0].effect=NoSchedule" \
    --set "daemonsets.tolerations[1].key=workload" \
    --set "daemonsets.tolerations[1].operator=Equal" \
    --set "daemonsets.tolerations[1].value=${GPU_NODE_WORKLOAD_LABEL}" \
    --set "daemonsets.tolerations[1].effect=NoSchedule" \
    --set "daemonsets.tolerations[2].key=kubernetes.azure.com/scalesetpriority" \
    --set "daemonsets.tolerations[2].operator=Equal" \
    --set "daemonsets.tolerations[2].value=spot" \
    --set "daemonsets.tolerations[2].effect=NoSchedule" \
    --wait \
    --timeout 10m

  rm -f "${tmp_values_file}"

  log "Waiting for GPU Operator controller to be ready"
  kubectl -n "${GPU_OPERATOR_NAMESPACE}" rollout status deploy/gpu-operator --timeout=5m 2>/dev/null || true
}

require_env \
  AZ_SUBSCRIPTION_ID RESOURCE_GROUP CLUSTER_NAME GPU_SKU_NAME \
  GPU_DRIVER_TARGET_REPOSITORY GPU_OPERATOR_MIRROR_NVIDIA_REPOSITORY \
  GPU_OPERATOR_MIRROR_NVIDIA_CLOUD_NATIVE_REPOSITORY GPU_OPERATOR_MIRROR_NVIDIA_K8S_REPOSITORY \
  GPU_OPERATOR_MIRROR_NFD_REPOSITORY

if [[ -z "${GPU_DRIVER_NODE_SELECTOR_VALUE:-}" ]]; then
  IFS='_' read -r -a gpu_sku_parts <<<"${GPU_SKU_NAME}"
  (( ${#gpu_sku_parts[@]} >= 2 )) || fail "Unable to derive GPU selector value from GPU_SKU_NAME=${GPU_SKU_NAME}"
  GPU_DRIVER_NODE_SELECTOR_VALUE="${gpu_sku_parts[${#gpu_sku_parts[@]}-2]}"
fi

EXPECTED_DRIVER_SELECTOR="${GPU_DRIVER_NODE_SELECTOR_KEY}=${GPU_DRIVER_NODE_SELECTOR_VALUE}"

az account set --subscription "${AZ_SUBSCRIPTION_ID}" --only-show-errors
export AZURE_SUBSCRIPTION_ID="${AZ_SUBSCRIPTION_ID}"

az aks get-credentials \
  --resource-group "${RESOURCE_GROUP}" \
  --name "${CLUSTER_NAME}" \
  --overwrite-existing \
  --only-show-errors \
  >/dev/null

# ── 1. 安装 GPU Operator (driver disabled) ────────────────────────
ensure_gpu_operator_controller

# ── 2. 部署 NVIDIADriver CR ──────────────────────────────────────
log "Validating GPU nodes for selector ${EXPECTED_DRIVER_SELECTOR}"
matching_gpu_nodes="$(kubectl get nodes -l "${EXPECTED_DRIVER_SELECTOR}" -o name 2>/dev/null || true)"
if [[ -z "${matching_gpu_nodes}" ]]; then
  kubectl get nodes -L workload,gputype,karpenter.azure.com/sku-gpu-name,node.kubernetes.io/instance-type 2>/dev/null || true
  if [[ "${GPU_DRIVER_REQUIRE_MATCHING_NODES}" == "true" ]]; then
    fail "No GPU nodes match ${EXPECTED_DRIVER_SELECTOR}; adjust 15-deploy-karpenter.sh labels or the NVIDIADriver selector before continuing"
  fi
  warn "No GPU nodes currently match ${EXPECTED_DRIVER_SELECTOR}; continuing to apply NVIDIADriver CR so future Karpenter nodes install the driver automatically"
fi

gpu_node_os_id=""
gpu_node_os_version=""
if [[ -n "${matching_gpu_nodes}" ]]; then
  gpu_node_os_id="$(kubectl get nodes -l "${EXPECTED_DRIVER_SELECTOR}" -o jsonpath='{.items[0].metadata.labels.feature\.node\.kubernetes\.io/system-os_release\.ID}' 2>/dev/null || true)"
  gpu_node_os_version="$(kubectl get nodes -l "${EXPECTED_DRIVER_SELECTOR}" -o jsonpath='{.items[0].metadata.labels.feature\.node\.kubernetes\.io/system-os_release\.VERSION_ID}' 2>/dev/null || true)"
fi

resolved_driver_image="${GPU_DRIVER_TARGET_REPOSITORY}/${GPU_DRIVER_IMAGE}:${GPU_DRIVER_VERSION}"
resolved_driver_image_note=""
if [[ -n "${gpu_node_os_id}" && -n "${gpu_node_os_version}" ]]; then
  resolved_driver_image="${resolved_driver_image}-${gpu_node_os_id,,}${gpu_node_os_version}"
else
  resolved_driver_image_note="Will resolve to an OS-specific image tag after a matching GPU node joins the cluster."
fi

existing_selector="$(kubectl get nvidiadriver "${GPU_DRIVER_CR_NAME}" -o go-template='{{range $k, $v := .spec.nodeSelector}}{{printf "%s=%s" $k $v}}{{end}}' 2>/dev/null || true)"
if [[ -n "${existing_selector}" && "${existing_selector}" != "${EXPECTED_DRIVER_SELECTOR}" ]]; then
  log "Existing NVIDIADriver selector is stale: ${existing_selector}"
  log "Recreating ${GPU_DRIVER_CR_NAME} with selector ${EXPECTED_DRIVER_SELECTOR}"
  kubectl delete nvidiadriver "${GPU_DRIVER_CR_NAME}" --ignore-not-found --wait=true
fi

log "Applying NVIDIADriver CR for RTX PRO 6000 BSE"
log "  driver source image: ${GPU_DRIVER_SOURCE_REPOSITORY}/${GPU_DRIVER_IMAGE}:${GPU_DRIVER_VERSION} (vgpu)"
log "  driver target image: ${GPU_DRIVER_TARGET_REPOSITORY}/${GPU_DRIVER_IMAGE}:${GPU_DRIVER_VERSION}"
log "  resolved driver image on current GPU nodes: ${resolved_driver_image}"
if [[ -n "${resolved_driver_image_note}" ]]; then
  log "  note: ${resolved_driver_image_note}"
fi
kubectl apply -f - <<EOF
apiVersion: nvidia.com/v1alpha1
kind: NVIDIADriver
metadata:
  name: ${GPU_DRIVER_CR_NAME}
spec:
  tolerations:
    - key: "workload"
      operator: "Equal"
      value: "${GPU_NODE_WORKLOAD_LABEL}"
      effect: "NoSchedule"
    - key: "kubernetes.azure.com/scalesetpriority"
      operator: "Equal"
      value: "spot"
      effect: "NoSchedule"
    - key: "nvidia.com/gpu"
      operator: "Exists"
      effect: "NoSchedule"
  nodeSelector:
    ${GPU_DRIVER_NODE_SELECTOR_KEY}: "${GPU_DRIVER_NODE_SELECTOR_VALUE}"
  driverType: vgpu
  image: ${GPU_DRIVER_IMAGE}
  repository: "${GPU_DRIVER_TARGET_REPOSITORY}"
  version: "${GPU_DRIVER_VERSION}"
EOF

applied_selector="$(kubectl get nvidiadriver "${GPU_DRIVER_CR_NAME}" -o go-template='{{range $k, $v := .spec.nodeSelector}}{{printf "%s=%s" $k $v}}{{end}}')"
[[ "${applied_selector}" == "${EXPECTED_DRIVER_SELECTOR}" ]] || fail "NVIDIADriver selector mismatch after apply: expected ${EXPECTED_DRIVER_SELECTOR}, got ${applied_selector}"

# ── 3. 显示状态 ──────────────────────────────────────────────────
log ""
log "GPU Operator deployment completed"
log "  Namespace       : ${GPU_OPERATOR_NAMESPACE}"
log "  Driver          : disabled (managed by NVIDIADriver CR)"
log "  NVIDIADriver CR : ${GPU_DRIVER_CR_NAME} (${GPU_DRIVER_TARGET_REPOSITORY}/${GPU_DRIVER_IMAGE}:${GPU_DRIVER_VERSION})"
log "  Node selector   : ${applied_selector}"
log "  Resolved image  : ${resolved_driver_image}"
log ""
log "GPU Operator components:"
kubectl -n "${GPU_OPERATOR_NAMESPACE}" get pods -o wide 2>/dev/null || true
log ""
log "NVIDIADriver status:"
kubectl get nvidiadrivers.nvidia.com -o wide 2>/dev/null || true
log ""
log "⚠ NOTE: NVIDIADriver pods will only appear after GPU nodes join the cluster."
log "  Check driver pod status: kubectl -n ${GPU_OPERATOR_NAMESPACE} get pods -l app=nvidia-driver-daemonset"
