#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 31-destroy-test-app.sh  —  删除 GPU 测试应用
# ---------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/common.sh"

load_env
ensure_tooling
require_env AZ_SUBSCRIPTION_ID RESOURCE_GROUP CLUSTER_NAME APP_NAMESPACE APP_NAME

DESTROY_APP_NAMESPACE_WAIT_TIMEOUT="${DESTROY_APP_NAMESPACE_WAIT_TIMEOUT:-300}"

az account set --subscription "${AZ_SUBSCRIPTION_ID}" --only-show-errors
if ! aks_exists; then
  warn "AKS cluster ${CLUSTER_NAME} does not exist, nothing to delete"
  exit 0
fi

if ! az aks get-credentials \
  --resource-group "${RESOURCE_GROUP}" \
  --name "${CLUSTER_NAME}" \
  --overwrite-existing \
  --only-show-errors \
  >/dev/null 2>&1; then
  warn "Failed to fetch AKS credentials for ${CLUSTER_NAME}, skipping test app deletion"
  exit 0
fi

if ! kubectl get namespace "${APP_NAMESPACE}" >/dev/null 2>&1; then
  log "Namespace ${APP_NAMESPACE} does not exist, nothing to delete"
  exit 0
fi

log "Deleting workload resources for ${APP_NAME} in namespace ${APP_NAMESPACE}"
kubectl -n "${APP_NAMESPACE}" delete service "${APP_NAME}" --ignore-not-found=true >/dev/null
kubectl -n "${APP_NAMESPACE}" delete deployment "${APP_NAME}" --ignore-not-found=true >/dev/null
kubectl delete priorityclass "${APP_NAME}-priority" --ignore-not-found=true >/dev/null

if [[ "${DELETE_APP_NAMESPACE:-false}" == "true" ]]; then
  log "Deleting namespace ${APP_NAMESPACE}"
  kubectl delete namespace "${APP_NAMESPACE}" --ignore-not-found=true >/dev/null 2>&1 || true
  if wait_for_namespace_deleted "${APP_NAMESPACE}" "${DESTROY_APP_NAMESPACE_WAIT_TIMEOUT}"; then
    log "Namespace ${APP_NAMESPACE} deleted"
  else
    warn "Namespace ${APP_NAMESPACE} is still terminating; test app cleanup will continue"
  fi
else
  log "Keeping namespace ${APP_NAMESPACE}. Set DELETE_APP_NAMESPACE=true to remove it as well."
  kubectl -n "${APP_NAMESPACE}" get all --ignore-not-found
fi
