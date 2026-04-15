#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 99-cleanup.sh  —  清理所有 GPU 测试资源
#
# 默认行为:
#   - 删除 qwen loadtest 工作负载
#   - 删除测试应用
#   - 卸载 GPU Operator
#   - 卸载 Karpenter
#   - 删除 AKS 集群
#   - 删除 Resource Group (需设置 DELETE_RESOURCE_GROUP=true)
#   - 清理本地 .generated.env 文件
# ---------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../../common.sh"

load_env
ensure_tooling
require_env AZ_SUBSCRIPTION_ID RESOURCE_GROUP APP_NAMESPACE KARPENTER_NAMESPACE

CLEANUP_NODEPOOL_SETTLE_SECONDS="${CLEANUP_NODEPOOL_SETTLE_SECONDS:-30}"
CLEANUP_HELM_TIMEOUT="${CLEANUP_HELM_TIMEOUT:-120s}"
CLEANUP_NAMESPACE_WAIT_TIMEOUT="${CLEANUP_NAMESPACE_WAIT_TIMEOUT:-300}"
CLEANUP_RG_WAIT_TIMEOUT="${CLEANUP_RG_WAIT_TIMEOUT:-1200}"
AKS_DELETE_TIMEOUT="${AKS_DELETE_TIMEOUT:-1800}"
QWEN_DESTROY_SCRIPT="${ROOT_DIR}/04-workloads/qwen-loadtest-target/43-destroy.sh"
CERT_MANAGER_DESTROY_SCRIPT="${ROOT_DIR}/01-environment/shell/13-destroy-cert-manager.sh"

az account set --subscription "${AZ_SUBSCRIPTION_ID}" --only-show-errors

# ── 1. 卸载集群内资源 (需要集群存在) ──────────────────────────────
if aks_exists; then
  az aks get-credentials \
    --resource-group "${RESOURCE_GROUP}" \
    --name "${CLUSTER_NAME}" \
    --overwrite-existing \
    --only-show-errors \
    >/dev/null 2>&1 || true

  if [[ "${CLEANUP_QWEN_LOADTEST:-true}" == "true" && -x "${QWEN_DESTROY_SCRIPT}" ]]; then
    log "Deleting qwen loadtest resources before removing shared platform components"
    DELETE_QWEN_LOADTEST_NAMESPACE="${DELETE_QWEN_LOADTEST_NAMESPACE:-true}" \
      "${QWEN_DESTROY_SCRIPT}" || warn "Qwen loadtest cleanup did not finish cleanly; continuing cleanup"
  fi

  if [[ "${CLEANUP_CERT_MANAGER:-true}" == "true" && -x "${CERT_MANAGER_DESTROY_SCRIPT}" ]]; then
    log "Deleting cert-manager platform resources"
    "${CERT_MANAGER_DESTROY_SCRIPT}" || warn "cert-manager cleanup did not finish cleanly; continuing cleanup"
  fi

  # 先删除测试应用, 释放 Pod, 否则 nodeclaim 无法回收
  if kubectl get namespace "${APP_NAMESPACE}" >/dev/null 2>&1; then
    log "Deleting test app workloads in ${APP_NAMESPACE} before removing NodePools"
    kubectl -n "${APP_NAMESPACE}" delete deployment "${APP_NAME:-gpu-probe}" --ignore-not-found=true 2>/dev/null || true
    kubectl -n "${APP_NAMESPACE}" delete service "${APP_NAME:-gpu-probe}" --ignore-not-found=true 2>/dev/null || true
    kubectl delete priorityclass "${APP_NAME:-gpu-probe}-priority" --ignore-not-found=true 2>/dev/null || true
    # 等待 Pod 完全终止
    log "Waiting for pods to terminate"
    kubectl -n "${APP_NAMESPACE}" wait --for=delete pod --all --timeout=120s 2>/dev/null || true
  fi

  # 卸载 GPU Operator (在删除 NodePool 之前, 让 driver pod 先清理)
  GPU_OPERATOR_NAMESPACE="${GPU_OPERATOR_NAMESPACE:-gpu-operator}"
  log "Deleting NVIDIADriver CRs"
  kubectl delete nvidiadrivers.nvidia.com --all --ignore-not-found=true 2>/dev/null || true
  sleep 10
  log "Uninstalling GPU Operator Helm release"
  if ! helm uninstall gpu-operator --namespace "${GPU_OPERATOR_NAMESPACE}" --wait --timeout "${CLEANUP_HELM_TIMEOUT}" 2>/dev/null; then
    warn "Helm release gpu-operator uninstall did not finish cleanly; continuing cleanup"
  fi
  if kubectl get namespace "${GPU_OPERATOR_NAMESPACE}" >/dev/null 2>&1; then
    kubectl delete namespace "${GPU_OPERATOR_NAMESPACE}" --ignore-not-found=true --timeout=60s 2>/dev/null || true
  fi

  log "Removing Karpenter NodePool and AKSNodeClass"
  kubectl delete nodepools --all --ignore-not-found=true 2>/dev/null || true
  kubectl delete aksnodeclasses --all --ignore-not-found=true 2>/dev/null || true

  log "Waiting for Karpenter to drain GPU nodes (may take longer for large VMs)"
  sleep "${CLEANUP_NODEPOOL_SETTLE_SECONDS}"

  log "Uninstalling Karpenter Helm releases"
  if ! helm uninstall karpenter --namespace "${KARPENTER_NAMESPACE}" --wait --timeout "${CLEANUP_HELM_TIMEOUT}" 2>/dev/null; then
    warn "Helm release karpenter uninstall did not finish cleanly within ${CLEANUP_HELM_TIMEOUT}; continuing cleanup"
  fi
  if ! helm uninstall karpenter-crd --namespace "${KARPENTER_NAMESPACE}" --wait --timeout "${CLEANUP_HELM_TIMEOUT}" 2>/dev/null; then
    warn "Helm release karpenter-crd uninstall did not finish cleanly within ${CLEANUP_HELM_TIMEOUT}; continuing cleanup"
  fi

  log "Deleting namespace ${APP_NAMESPACE}"
  if kubectl get namespace "${APP_NAMESPACE}" >/dev/null 2>&1; then
    kubectl delete namespace "${APP_NAMESPACE}" --ignore-not-found=true >/dev/null 2>&1 || true
    if wait_for_namespace_deleted "${APP_NAMESPACE}" "${CLEANUP_NAMESPACE_WAIT_TIMEOUT}"; then
      log "Namespace ${APP_NAMESPACE} deleted"
    else
      warn "Namespace ${APP_NAMESPACE} is still terminating; cleanup will continue"
    fi
  else
    log "Namespace ${APP_NAMESPACE} does not exist"
  fi
fi

# ── 2. 删除 AKS 集群 ─────────────────────────────────────────────
if aks_exists; then
  log "Deleting AKS cluster ${CLUSTER_NAME}"
  az aks delete \
    --name "${CLUSTER_NAME}" \
    --resource-group "${RESOURCE_GROUP}" \
    --yes \
    --no-wait \
    --only-show-errors \
    >/dev/null || warn "az aks delete failed to start; it may already be deleting"

  log "Waiting up to ${AKS_DELETE_TIMEOUT}s for AKS deletion"
  elapsed=0
  poll_interval=20
  while (( elapsed < AKS_DELETE_TIMEOUT )); do
    if ! aks_exists; then
      log "AKS cluster ${CLUSTER_NAME} deleted"
      break
    fi
    sleep "${poll_interval}"
    elapsed=$((elapsed + poll_interval))
  done

  if aks_exists; then
    warn "Timed out waiting for AKS deletion; the operation may still be in progress"
  fi
else
  log "AKS cluster ${CLUSTER_NAME} does not exist"
fi

# ── 3. 删除 Resource Group ────────────────────────────────────────
if [[ "${DELETE_RESOURCE_GROUP:-false}" == "true" ]]; then
  log "Deleting resource group ${RESOURCE_GROUP}"
  if [[ "$(resource_group_exists)" == "true" ]]; then
    az group delete --name "${RESOURCE_GROUP}" --yes --no-wait --only-show-errors >/dev/null || true
    if wait_for_resource_group_deleted "${CLEANUP_RG_WAIT_TIMEOUT}"; then
      log "Resource group ${RESOURCE_GROUP} deleted"
    else
      warn "Resource group ${RESOURCE_GROUP} delete is still in progress; cleanup will exit without blocking further"
    fi
  else
    log "Resource group ${RESOURCE_GROUP} does not exist"
  fi
else
  log "Skipping resource group deletion. Set DELETE_RESOURCE_GROUP=true to remove Azure resources."
  if [[ "$(resource_group_exists)" == "true" ]]; then
    log "Resource group ${RESOURCE_GROUP} still exists"
  else
    log "Resource group ${RESOURCE_GROUP} does not exist"
  fi
fi

# ── 4. 清理本地文件 ───────────────────────────────────────────────
log "Removing local generated env file"
if [[ -f "${GENERATED_ENV_FILE}" ]]; then
  rm -f "${GENERATED_ENV_FILE}"
  log "Removed ${GENERATED_ENV_FILE}"
else
  log "Generated env file ${GENERATED_ENV_FILE} does not exist"
fi

log "Cleanup completed"
