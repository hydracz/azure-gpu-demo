#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../../../common.sh"

CALLER_LABEL="${1:-terraform}"

probe_backend_container() {
  az storage container exists \
    --account-name "${TFSTATE_STORAGE_ACCOUNT}" \
    --name "${TFSTATE_CONTAINER}" \
    --auth-mode login \
    --query exists \
    -o tsv \
    --only-show-errors
}

load_env
need_cmd az
require_env TFSTATE_RESOURCE_GROUP TFSTATE_STORAGE_ACCOUNT TFSTATE_CONTAINER

if [[ -n "${AZ_SUBSCRIPTION_ID:-}" ]]; then
  az account set --subscription "${AZ_SUBSCRIPTION_ID}" --only-show-errors >/dev/null
fi

account_kind="$(az storage account show \
  --resource-group "${TFSTATE_RESOURCE_GROUP}" \
  --name "${TFSTATE_STORAGE_ACCOUNT}" \
  --query kind \
  -o tsv \
  --only-show-errors)"

public_network_access="$(az storage account show \
  --resource-group "${TFSTATE_RESOURCE_GROUP}" \
  --name "${TFSTATE_STORAGE_ACCOUNT}" \
  --query publicNetworkAccess \
  -o tsv \
  --only-show-errors)"

default_action="$(az storage account show \
  --resource-group "${TFSTATE_RESOURCE_GROUP}" \
  --name "${TFSTATE_STORAGE_ACCOUNT}" \
  --query networkRuleSet.defaultAction \
  -o tsv \
  --only-show-errors)"

blob_endpoint="$(az storage account show \
  --resource-group "${TFSTATE_RESOURCE_GROUP}" \
  --name "${TFSTATE_STORAGE_ACCOUNT}" \
  --query primaryEndpoints.blob \
  -o tsv \
  --only-show-errors)"

log "${CALLER_LABEL}: Terraform backend uses azurerm on storage account ${TFSTATE_STORAGE_ACCOUNT} (kind=${account_kind}, publicNetworkAccess=${public_network_access}, defaultAction=${default_action}, blobEndpoint=${blob_endpoint})"

probe_result="$(probe_backend_container 2>/dev/null || true)"

if [[ "${probe_result}" == "true" ]]; then
  log "${CALLER_LABEL}: Terraform backend container ${TFSTATE_CONTAINER} is reachable"
  exit 0
fi

if [[ "${probe_result}" == "false" ]]; then
  fail "${CALLER_LABEL}: Terraform backend container ${TFSTATE_CONTAINER} does not exist in storage account ${TFSTATE_STORAGE_ACCOUNT}"
fi

log "${CALLER_LABEL}: Terraform backend probe failed; enabling public network access and allowing traffic on storage account ${TFSTATE_STORAGE_ACCOUNT}"
az storage account update \
  --resource-group "${TFSTATE_RESOURCE_GROUP}" \
  --name "${TFSTATE_STORAGE_ACCOUNT}" \
  --public-network-access Enabled \
  --default-action Allow \
  --only-show-errors \
  >/dev/null

probe_result="$(probe_backend_container 2>/dev/null || true)"

if [[ "${probe_result}" == "true" ]]; then
  log "${CALLER_LABEL}: Terraform backend container ${TFSTATE_CONTAINER} is reachable after storage account remediation"
  exit 0
fi

if [[ "${probe_result}" == "false" ]]; then
  fail "${CALLER_LABEL}: Terraform backend container ${TFSTATE_CONTAINER} does not exist in storage account ${TFSTATE_STORAGE_ACCOUNT}"
fi

fail "${CALLER_LABEL}: Terraform backend container ${TFSTATE_CONTAINER} is still unreachable after enabling public network access; confirm Blob data-plane RBAC and any policy re-applying deny rules"