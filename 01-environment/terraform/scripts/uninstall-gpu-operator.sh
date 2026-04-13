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
[[ -n "${GPU_OPERATOR_NAMESPACE:-}" ]] || fail "GPU_OPERATOR_NAMESPACE is required"

refresh_aks_kubeconfig

kubectl delete nvidiadriver "${GPU_DRIVER_CR_NAME:-rtxpro6000-azure}" --ignore-not-found >/dev/null 2>&1 || true
helm uninstall gpu-operator --namespace "${GPU_OPERATOR_NAMESPACE}" >/dev/null 2>&1 || true