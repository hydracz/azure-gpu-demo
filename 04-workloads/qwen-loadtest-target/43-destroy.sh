#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../../common.sh"

load_env
need_cmd kubectl

require_env AZ_SUBSCRIPTION_ID RESOURCE_GROUP CLUSTER_NAME

ensure_aks_kubeconfig

QWEN_LOADTEST_NAMESPACE="${QWEN_LOADTEST_NAMESPACE:-qwen-loadtest}"
QWEN_LOADTEST_NAME="${QWEN_LOADTEST_NAME:-qwen-loadtest-target}"
QWEN_LOADTEST_SERVICE_NAME="${QWEN_LOADTEST_SERVICE_NAME:-${QWEN_LOADTEST_NAME}}"
QWEN_LOADTEST_CERTIFICATE_NAME="${QWEN_LOADTEST_CERTIFICATE_NAME:-${QWEN_LOADTEST_NAME}}"
QWEN_LOADTEST_GATEWAY_NAME="${QWEN_LOADTEST_GATEWAY_NAME:-qwen-loadtest-external}"
QWEN_LOADTEST_TLS_SECRET_NAME="${QWEN_LOADTEST_TLS_SECRET_NAME:-qwen-loadtest-target-tls}"
QWEN_LOADTEST_GATEWAY_WORKLOAD_NAMESPACE="${QWEN_LOADTEST_GATEWAY_WORKLOAD_NAMESPACE:-aks-istio-ingress}"
QWEN_LOADTEST_IMAGE_PULL_SECRET_NAME="${QWEN_LOADTEST_IMAGE_PULL_SECRET_NAME:-qwen-loadtest-source-regcred}"

if ! kubectl get namespace "${QWEN_LOADTEST_NAMESPACE}" >/dev/null 2>&1; then
  log "Namespace ${QWEN_LOADTEST_NAMESPACE} does not exist, nothing to delete"
else
  kubectl delete scaledobject.keda.sh "${QWEN_LOADTEST_NAME}" -n "${QWEN_LOADTEST_NAMESPACE}" --ignore-not-found >/dev/null 2>&1 || true
  kubectl delete destinationrule.networking.istio.io "${QWEN_LOADTEST_NAME}" -n "${QWEN_LOADTEST_NAMESPACE}" --ignore-not-found >/dev/null 2>&1 || true
  kubectl delete virtualservice.networking.istio.io "${QWEN_LOADTEST_NAME}" -n "${QWEN_LOADTEST_NAMESPACE}" --ignore-not-found >/dev/null 2>&1 || true
  kubectl delete gateway.networking.istio.io "${QWEN_LOADTEST_GATEWAY_NAME}" -n "${QWEN_LOADTEST_NAMESPACE}" --ignore-not-found >/dev/null 2>&1 || true
  kubectl delete service "${QWEN_LOADTEST_SERVICE_NAME}" -n "${QWEN_LOADTEST_NAMESPACE}" --ignore-not-found >/dev/null 2>&1 || true
  kubectl delete deployment "${QWEN_LOADTEST_NAME}" -n "${QWEN_LOADTEST_NAMESPACE}" --ignore-not-found >/dev/null 2>&1 || true
  kubectl delete secret "${QWEN_LOADTEST_IMAGE_PULL_SECRET_NAME}" -n "${QWEN_LOADTEST_NAMESPACE}" --ignore-not-found >/dev/null 2>&1 || true

  if [[ "${DELETE_QWEN_LOADTEST_NAMESPACE:-false}" == "true" ]]; then
    kubectl delete namespace "${QWEN_LOADTEST_NAMESPACE}" --ignore-not-found >/dev/null 2>&1 || true
    wait_for_namespace_deleted "${QWEN_LOADTEST_NAMESPACE}" 300 || true
  else
    kubectl label namespace "${QWEN_LOADTEST_NAMESPACE}" istio.io/rev- >/dev/null 2>&1 || true
    kubectl -n "${QWEN_LOADTEST_NAMESPACE}" get all --ignore-not-found || true
  fi
fi

kubectl delete certificate.cert-manager.io "${QWEN_LOADTEST_CERTIFICATE_NAME}" -n "${QWEN_LOADTEST_GATEWAY_WORKLOAD_NAMESPACE}" --ignore-not-found >/dev/null 2>&1 || true

if [[ "${DELETE_QWEN_LOADTEST_TLS_SECRET:-true}" == "true" ]]; then
  kubectl delete secret "${QWEN_LOADTEST_TLS_SECRET_NAME}" -n "${QWEN_LOADTEST_GATEWAY_WORKLOAD_NAMESPACE}" --ignore-not-found >/dev/null 2>&1 || true
fi

log "Qwen loadtest resources removed"