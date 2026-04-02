#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 18-destroy-gpu-operator.sh  —  卸载 NVIDIA GPU Operator
# ---------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/common.sh"

load_env
ensure_tooling

GPU_OPERATOR_NAMESPACE="${GPU_OPERATOR_NAMESPACE:-gpu-operator}"
DESTROY_GPU_OPERATOR_TIMEOUT="${DESTROY_GPU_OPERATOR_TIMEOUT:-120s}"

if ! aks_exists; then
  warn "AKS cluster ${CLUSTER_NAME} does not exist; skipping GPU Operator uninstall"
  exit 0
fi

if ! az aks get-credentials \
  --resource-group "${RESOURCE_GROUP}" \
  --name "${CLUSTER_NAME}" \
  --overwrite-existing \
  --only-show-errors \
  >/dev/null 2>&1; then
  warn "Failed to fetch AKS credentials for ${CLUSTER_NAME}; skipping GPU Operator uninstall"
  exit 0
fi

# 先删除 NVIDIADriver CR
log "Deleting NVIDIADriver CRs"
kubectl delete nvidiadrivers.nvidia.com --all --ignore-not-found=true 2>/dev/null || true

log "Waiting for driver pods to terminate"
sleep 15

# 卸载 GPU Operator Helm release
log "Uninstalling gpu-operator Helm release"
if ! helm uninstall gpu-operator --namespace "${GPU_OPERATOR_NAMESPACE}" --wait --timeout "${DESTROY_GPU_OPERATOR_TIMEOUT}" 2>/dev/null; then
  warn "Helm release gpu-operator uninstall did not finish cleanly within ${DESTROY_GPU_OPERATOR_TIMEOUT}; continuing"
fi

# 清理 namespace
if kubectl get namespace "${GPU_OPERATOR_NAMESPACE}" >/dev/null 2>&1; then
  log "Deleting namespace ${GPU_OPERATOR_NAMESPACE}"
  kubectl delete namespace "${GPU_OPERATOR_NAMESPACE}" --ignore-not-found=true --timeout=120s 2>/dev/null || true
fi

log "GPU Operator uninstalled"
