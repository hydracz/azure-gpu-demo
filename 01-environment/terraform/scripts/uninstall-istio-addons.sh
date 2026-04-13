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
[[ -n "${ISTIO_KIALI_NAMESPACE:-}" ]] || fail "ISTIO_KIALI_NAMESPACE is required"
[[ -n "${ISTIO_KIALI_ENABLED:-}" ]] || fail "ISTIO_KIALI_ENABLED is required"
[[ -n "${ISTIO_KIALI_PROXY_SERVICE_NAME:-}" ]] || fail "ISTIO_KIALI_PROXY_SERVICE_NAME is required"
[[ -n "${ISTIO_KIALI_PROXY_SERVICE_ACCOUNT_NAME:-}" ]] || fail "ISTIO_KIALI_PROXY_SERVICE_ACCOUNT_NAME is required"

refresh_aks_kubeconfig || exit 0

if [[ "${ISTIO_KIALI_ENABLED}" != "true" ]]; then
  exit 0
fi

kubectl delete kiali kiali -n "${ISTIO_KIALI_NAMESPACE}" --ignore-not-found >/dev/null 2>&1 || true
helm uninstall kiali-operator -n "${ISTIO_KIALI_NAMESPACE}" >/dev/null 2>&1 || true
kubectl delete service "${ISTIO_KIALI_PROXY_SERVICE_NAME}" -n "${ISTIO_KIALI_NAMESPACE}" --ignore-not-found >/dev/null 2>&1 || true
kubectl delete deployment "${ISTIO_KIALI_PROXY_SERVICE_NAME}" -n "${ISTIO_KIALI_NAMESPACE}" --ignore-not-found >/dev/null 2>&1 || true
kubectl delete serviceaccount "${ISTIO_KIALI_PROXY_SERVICE_ACCOUNT_NAME}" -n "${ISTIO_KIALI_NAMESPACE}" --ignore-not-found >/dev/null 2>&1 || true