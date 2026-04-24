#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 16-destroy-karpenter.sh  —  卸载 Karpenter 及其 CRD
# ---------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../../common.sh"

load_env
ensure_tooling
require_env KARPENTER_NAMESPACE

DESTROY_NODEPOOL_SETTLE_SECONDS="${DESTROY_NODEPOOL_SETTLE_SECONDS:-30}"
DESTROY_HELM_TIMEOUT="${DESTROY_HELM_TIMEOUT:-120s}"

if ! aks_exists; then
  warn "AKS cluster ${CLUSTER_NAME} does not exist; skipping Karpenter uninstall"
  exit 0
fi

if ! try_ensure_aks_kubeconfig; then
  warn "Failed to fetch AKS credentials for ${CLUSTER_NAME}; skipping Karpenter uninstall"
  exit 0
fi

log "Deleting Karpenter NodePool and AKSNodeClass resources"
kubectl delete nodepools --all --ignore-not-found=true 2>/dev/null || true
kubectl delete aksnodeclasses --all --ignore-not-found=true 2>/dev/null || true

log "Waiting for Karpenter to drain managed GPU nodes (this may take longer for GPU VMs)"
sleep "${DESTROY_NODEPOOL_SETTLE_SECONDS}"

log "Uninstalling karpenter Helm release"
if ! helm uninstall karpenter --namespace "${KARPENTER_NAMESPACE}" --wait --timeout "${DESTROY_HELM_TIMEOUT}" 2>/dev/null; then
  warn "Helm release karpenter uninstall did not finish cleanly within ${DESTROY_HELM_TIMEOUT}; continuing"
fi

log "Uninstalling karpenter-crd Helm release"
if ! helm uninstall karpenter-crd --namespace "${KARPENTER_NAMESPACE}" --wait --timeout "${DESTROY_HELM_TIMEOUT}" 2>/dev/null; then
  warn "Helm release karpenter-crd uninstall did not finish cleanly within ${DESTROY_HELM_TIMEOUT}; continuing"
fi

log "Karpenter uninstalled"
