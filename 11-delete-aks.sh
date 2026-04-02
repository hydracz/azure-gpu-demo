#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/common.sh"

load_env
ensure_tooling
require_env AZ_SUBSCRIPTION_ID RESOURCE_GROUP CLUSTER_NAME

AKS_DELETE_TIMEOUT="${AKS_DELETE_TIMEOUT:-1800}"
POLL_INTERVAL="${POLL_INTERVAL:-20}"

az account set --subscription "${AZ_SUBSCRIPTION_ID}" --only-show-errors

if aks_exists; then
  log "Deleting AKS cluster ${CLUSTER_NAME} in resource group ${RESOURCE_GROUP}"
  az aks delete \
    --name "${CLUSTER_NAME}" \
    --resource-group "${RESOURCE_GROUP}" \
    --yes \
    --no-wait \
    --only-show-errors \
    >/dev/null || warn "az aks delete failed to start; it may already be deleting"

  log "Waiting up to ${AKS_DELETE_TIMEOUT}s for AKS deletion"
  elapsed=0
  while (( elapsed < AKS_DELETE_TIMEOUT )); do
    if ! aks_exists; then
      log "AKS cluster ${CLUSTER_NAME} deleted"
      break
    fi
    sleep "${POLL_INTERVAL}"
    elapsed=$((elapsed + POLL_INTERVAL))
  done

  if aks_exists; then
    warn "Timed out waiting for AKS deletion; the operation may still be in progress in Azure"
  fi
else
  log "AKS cluster ${CLUSTER_NAME} does not exist"
fi

if [[ "${DELETE_NODE_RESOURCE_GROUP:-false}" == "true" ]]; then
  NODE_RG="${NODE_RESOURCE_GROUP:-}"
  if [[ -z "${NODE_RG}" ]]; then
    NODE_RG="$(az aks show --resource-group "${RESOURCE_GROUP}" --name "${CLUSTER_NAME}" --query nodeResourceGroup -o tsv --only-show-errors || true)"
  fi
  if [[ -n "${NODE_RG}" ]]; then
    if az group exists --name "${NODE_RG}" --only-show-errors | grep -q true; then
      log "Deleting node resource group ${NODE_RG}"
      az group delete --name "${NODE_RG}" --yes --no-wait --only-show-errors >/dev/null || warn "Failed starting node RG deletion"
    else
      log "Node resource group ${NODE_RG} does not exist"
    fi
  fi
fi

log "Removing local generated env file"
if [[ -f "${GENERATED_ENV_FILE}" ]]; then
  rm -f "${GENERATED_ENV_FILE}"
  log "Removed ${GENERATED_ENV_FILE}"
else
  log "Generated env file ${GENERATED_ENV_FILE} does not exist"
fi
