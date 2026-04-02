#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 05-create-network.sh  —  单独创建 AKS 自定义 VNet/Subnet
#
# 用于模拟"提前创建网络"的场景:
#   1. 创建独立的网络 Resource Group
#   2. 创建 VNet + AKS Subnet
#   3. 把 VNET_SUBNET_ID 写入 .generated.env，供 10-create-aks.sh 使用
# ---------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/common.sh"

load_env
need_cmd az
need_cmd python3

if [[ -n "${VNET_SUBNET_ID:-}" ]]; then
  require_env AZ_SUBSCRIPTION_ID LOCATION VNET_SUBNET_ID
else
  require_env \
    AZ_SUBSCRIPTION_ID LOCATION NETWORK_RESOURCE_GROUP \
    VNET_NAME VNET_ADDRESS_PREFIX AKS_SUBNET_NAME AKS_SUBNET_ADDRESS_PREFIX
fi

az account set --subscription "${AZ_SUBSCRIPTION_ID}" --only-show-errors

log "Registering Microsoft.Network resource provider"
az provider register --namespace Microsoft.Network --wait --only-show-errors >/dev/null

if [[ -n "${VNET_SUBNET_ID:-}" ]] && az network vnet subnet show --ids "${VNET_SUBNET_ID}" --only-show-errors >/dev/null 2>&1; then
  log "Using existing subnet from VNET_SUBNET_ID ${VNET_SUBNET_ID}"
  subnet_id="${VNET_SUBNET_ID}"
  vnet_id="${subnet_id%/subnets/*}"
  NETWORK_RESOURCE_GROUP="$(az network vnet show --ids "${vnet_id}" --query resourceGroup -o tsv --only-show-errors)"
  VNET_NAME="$(az network vnet show --ids "${vnet_id}" --query name -o tsv --only-show-errors)"
  VNET_ADDRESS_PREFIX="$(az network vnet show --ids "${vnet_id}" --query 'addressSpace.addressPrefixes[0]' -o tsv --only-show-errors)"
  AKS_SUBNET_NAME="$(az network vnet subnet show --ids "${subnet_id}" --query name -o tsv --only-show-errors)"
  AKS_SUBNET_ADDRESS_PREFIX="$(az network vnet subnet show --ids "${subnet_id}" --query 'addressPrefix' -o tsv --only-show-errors)"
else
  if [[ -n "${VNET_SUBNET_ID:-}" ]]; then
    warn "Configured VNET_SUBNET_ID ${VNET_SUBNET_ID} was not found; falling back to NETWORK_RESOURCE_GROUP/VNET_NAME/AKS_SUBNET_NAME settings"
  fi

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
    --query id \
    -o tsv \
    --only-show-errors)"
  subnet_id="$(az network vnet subnet show \
    --resource-group "${NETWORK_RESOURCE_GROUP}" \
    --vnet-name "${VNET_NAME}" \
    --name "${AKS_SUBNET_NAME}" \
    --query id \
    -o tsv \
    --only-show-errors)"

  VNET_ADDRESS_PREFIX="$(az network vnet show --ids "${vnet_id}" --query 'addressSpace.addressPrefixes[0]' -o tsv --only-show-errors)"
  AKS_SUBNET_ADDRESS_PREFIX="$(az network vnet subnet show --ids "${subnet_id}" --query 'addressPrefix' -o tsv --only-show-errors)"
fi

write_generated_env NETWORK_RESOURCE_GROUP "${NETWORK_RESOURCE_GROUP}"
write_generated_env VNET_NAME "${VNET_NAME}"
write_generated_env VNET_ID "${vnet_id}"
write_generated_env VNET_ADDRESS_PREFIX "${VNET_ADDRESS_PREFIX}"
write_generated_env AKS_SUBNET_NAME "${AKS_SUBNET_NAME}"
write_generated_env AKS_SUBNET_ADDRESS_PREFIX "${AKS_SUBNET_ADDRESS_PREFIX}"
write_generated_env AKS_SUBNET_ID "${subnet_id}"
write_generated_env VNET_SUBNET_ID "${subnet_id}"

log "Custom network bootstrap completed"
log "  Network RG : ${NETWORK_RESOURCE_GROUP}"
log "  VNet       : ${VNET_NAME} (${VNET_ADDRESS_PREFIX})"
log "  Subnet     : ${AKS_SUBNET_NAME} (${AKS_SUBNET_ADDRESS_PREFIX})"
log "  Subnet ID  : ${subnet_id}"
log "Next step: run 10-create-aks.sh to create AKS on the custom subnet"
