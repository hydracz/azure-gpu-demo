#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../../common.sh"

load_env
need_cmd az

existing_subnet_id="${EXISTING_VNET_SUBNET_ID:-}"

if [[ -n "${existing_subnet_id}" ]]; then
  require_env AZ_SUBSCRIPTION_ID LOCATION EXISTING_VNET_SUBNET_ID
else
  require_env \
    AZ_SUBSCRIPTION_ID LOCATION NETWORK_RESOURCE_GROUP \
    VNET_NAME VNET_ADDRESS_PREFIX AKS_SUBNET_NAME AKS_SUBNET_ADDRESS_PREFIX
fi

az account set --subscription "${AZ_SUBSCRIPTION_ID}" --only-show-errors >/dev/null

subnet_id=""
vnet_id=""

if [[ -n "${existing_subnet_id}" ]] && az network vnet subnet show --ids "${existing_subnet_id}" --only-show-errors >/dev/null 2>&1; then
  log "Using existing subnet from EXISTING_VNET_SUBNET_ID ${existing_subnet_id}"
  subnet_id="${existing_subnet_id}"
  vnet_id="${subnet_id%/subnets/*}"
  NETWORK_RESOURCE_GROUP="$(az network vnet show --ids "${vnet_id}" --query resourceGroup -o tsv --only-show-errors)"
  VNET_NAME="$(az network vnet show --ids "${vnet_id}" --query name -o tsv --only-show-errors)"
  VNET_ADDRESS_PREFIX="$(az network vnet show --ids "${vnet_id}" --query 'addressSpace.addressPrefixes[0]' -o tsv --only-show-errors)"
  AKS_SUBNET_NAME="$(az network vnet subnet show --ids "${subnet_id}" --query name -o tsv --only-show-errors)"
  AKS_SUBNET_ADDRESS_PREFIX="$(az network vnet subnet show --ids "${subnet_id}" --query addressPrefix -o tsv --only-show-errors)"
else
  if [[ -n "${existing_subnet_id}" ]]; then
    warn "Configured EXISTING_VNET_SUBNET_ID ${existing_subnet_id} was not found; falling back to NETWORK_RESOURCE_GROUP/VNET_NAME/AKS_SUBNET_NAME settings"
  fi

  require_env \
    AZ_SUBSCRIPTION_ID LOCATION NETWORK_RESOURCE_GROUP \
    VNET_NAME VNET_ADDRESS_PREFIX AKS_SUBNET_NAME AKS_SUBNET_ADDRESS_PREFIX

  if [[ "$(az group exists --name "${NETWORK_RESOURCE_GROUP}" --only-show-errors)" == "true" ]]; then
    log "Network resource group ${NETWORK_RESOURCE_GROUP} already exists"
  else
    log "Creating network resource group ${NETWORK_RESOURCE_GROUP}"
    az group create \
      --name "${NETWORK_RESOURCE_GROUP}" \
      --location "${LOCATION}" \
      --only-show-errors \
      >/dev/null
  fi

  if ! az network vnet show \
      --resource-group "${NETWORK_RESOURCE_GROUP}" \
      --name "${VNET_NAME}" \
      --only-show-errors >/dev/null 2>&1; then
    log "Creating VNet ${VNET_NAME} with subnet ${AKS_SUBNET_NAME}"
    az network vnet create \
      --resource-group "${NETWORK_RESOURCE_GROUP}" \
      --name "${VNET_NAME}" \
      --location "${LOCATION}" \
      --address-prefixes "${VNET_ADDRESS_PREFIX}" \
      --subnet-name "${AKS_SUBNET_NAME}" \
      --subnet-prefixes "${AKS_SUBNET_ADDRESS_PREFIX}" \
      --only-show-errors \
      >/dev/null
  else
    log "VNet ${VNET_NAME} already exists"
    if ! az network vnet subnet show \
        --resource-group "${NETWORK_RESOURCE_GROUP}" \
        --vnet-name "${VNET_NAME}" \
        --name "${AKS_SUBNET_NAME}" \
        --only-show-errors >/dev/null 2>&1; then
      log "Creating subnet ${AKS_SUBNET_NAME}"
      az network vnet subnet create \
        --resource-group "${NETWORK_RESOURCE_GROUP}" \
        --vnet-name "${VNET_NAME}" \
        --name "${AKS_SUBNET_NAME}" \
        --address-prefixes "${AKS_SUBNET_ADDRESS_PREFIX}" \
        --only-show-errors \
        >/dev/null
    else
      log "Subnet ${AKS_SUBNET_NAME} already exists"
    fi
  fi

  vnet_id="$(az network vnet show \
    --resource-group "${NETWORK_RESOURCE_GROUP}" \
    --name "${VNET_NAME}" \
    --query id -o tsv \
    --only-show-errors)"
  subnet_id="$(az network vnet subnet show \
    --resource-group "${NETWORK_RESOURCE_GROUP}" \
    --vnet-name "${VNET_NAME}" \
    --name "${AKS_SUBNET_NAME}" \
    --query id -o tsv \
    --only-show-errors)"
fi

subnet_nsg_name="${VNET_NAME}-${AKS_SUBNET_NAME}-nsg-${LOCATION}"

if ! az network nsg show \
    --resource-group "${NETWORK_RESOURCE_GROUP}" \
    --name "${subnet_nsg_name}" \
    --only-show-errors >/dev/null 2>&1; then
  log "Creating NSG ${subnet_nsg_name}"
  az network nsg create \
    --resource-group "${NETWORK_RESOURCE_GROUP}" \
    --name "${subnet_nsg_name}" \
    --location "${LOCATION}" \
    --only-show-errors \
    >/dev/null
else
  log "NSG ${subnet_nsg_name} already exists"
fi

if ! az network nsg rule show \
    --resource-group "${NETWORK_RESOURCE_GROUP}" \
    --nsg-name "${subnet_nsg_name}" \
    --name allow-http-common-ports \
    --only-show-errors >/dev/null 2>&1; then
  log "Creating NSG rule allow-http-common-ports"
  az network nsg rule create \
    --resource-group "${NETWORK_RESOURCE_GROUP}" \
    --nsg-name "${subnet_nsg_name}" \
    --name allow-http-common-ports \
    --priority 300 \
    --direction Inbound \
    --access Allow \
    --protocol Tcp \
    --source-port-ranges '*' \
    --destination-port-ranges 80 443 8080 8443 \
    --source-address-prefixes Internet \
    --destination-address-prefixes '*' \
    --only-show-errors \
    >/dev/null
else
  log "NSG rule allow-http-common-ports already exists"
fi

current_nsg_id="$(az network vnet subnet show --ids "${subnet_id}" --query 'networkSecurityGroup.id' -o tsv --only-show-errors 2>/dev/null || true)"
desired_nsg_id="$(az network nsg show --resource-group "${NETWORK_RESOURCE_GROUP}" --name "${subnet_nsg_name}" --query id -o tsv --only-show-errors)"
if [[ "${current_nsg_id}" != "${desired_nsg_id}" ]]; then
  log "Associating subnet ${AKS_SUBNET_NAME} with NSG ${subnet_nsg_name}"
  az network vnet subnet update \
    --ids "${subnet_id}" \
    --network-security-group "${desired_nsg_id}" \
    --only-show-errors \
    >/dev/null
fi

write_generated_env NETWORK_RESOURCE_GROUP "${NETWORK_RESOURCE_GROUP}"
write_generated_env VNET_NAME "${VNET_NAME}"
write_generated_env VNET_ADDRESS_PREFIX "${VNET_ADDRESS_PREFIX}"
write_generated_env AKS_SUBNET_NAME "${AKS_SUBNET_NAME}"
write_generated_env AKS_SUBNET_ADDRESS_PREFIX "${AKS_SUBNET_ADDRESS_PREFIX}"
write_generated_env AKS_SUBNET_NSG_NAME "${subnet_nsg_name}"
write_generated_env EXISTING_VNET_SUBNET_ID "${subnet_id}"
write_generated_env AKS_SUBNET_ID "${subnet_id}"

log "Network preparation completed"
log "  Network RG : ${NETWORK_RESOURCE_GROUP}"
log "  VNet       : ${VNET_NAME} (${VNET_ADDRESS_PREFIX})"
log "  Subnet     : ${AKS_SUBNET_NAME} (${AKS_SUBNET_ADDRESS_PREFIX})"
log "  NSG        : ${subnet_nsg_name}"
log "  Subnet ID  : ${subnet_id}"