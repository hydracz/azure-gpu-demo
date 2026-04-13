#!/usr/bin/env bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/common.sh"

need_cmd helm
need_cmd kubectl

[[ -n "${KUBECONFIG_FILE:-}" ]] || fail "KUBECONFIG_FILE is required"
[[ -n "${AZURE_SUBSCRIPTION_ID:-}" ]] || fail "AZURE_SUBSCRIPTION_ID is required"
[[ -n "${RESOURCE_GROUP:-}" ]] || fail "RESOURCE_GROUP is required"
[[ -n "${CLUSTER_NAME:-}" ]] || fail "CLUSTER_NAME is required"
[[ -n "${KARPENTER_NAMESPACE:-}" ]] || fail "KARPENTER_NAMESPACE is required"

refresh_aks_kubeconfig

kubectl delete nodepool "${KARPENTER_SPOT_POOL_NAME:-gpu-spot-pool}" --ignore-not-found >/dev/null 2>&1 || true
kubectl delete nodepool "${KARPENTER_OD_POOL_NAME:-gpu-ondemand-pool}" --ignore-not-found >/dev/null 2>&1 || true
kubectl delete aksnodeclass "${KARPENTER_NODECLASS_NAME:-gpu}" --ignore-not-found >/dev/null 2>&1 || true
helm uninstall "${KARPENTER_RELEASE_NAME:-karpenter}" --namespace "${KARPENTER_NAMESPACE}" >/dev/null 2>&1 || true
helm uninstall "${KARPENTER_CRD_RELEASE:-karpenter-crd}" --namespace "${KARPENTER_NAMESPACE}" >/dev/null 2>&1 || true