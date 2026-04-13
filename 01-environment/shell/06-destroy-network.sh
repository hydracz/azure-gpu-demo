#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 06-destroy-network.sh  —  删除 05-create-network.sh 创建的网络资源
#
# 只建议在以下前提下执行:
#   1. 当前 AKS 集群已删除
#   2. 没有其他资源仍在使用该 VNet/Subnet
# ---------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../../common.sh"

load_env
need_cmd az

require_env AZ_SUBSCRIPTION_ID NETWORK_RESOURCE_GROUP

az account set --subscription "${AZ_SUBSCRIPTION_ID}" --only-show-errors

if [[ "${DELETE_NETWORK_RESOURCE_GROUP:-false}" != "true" ]]; then
  log "Skipping network resource group deletion."
  log "Set DELETE_NETWORK_RESOURCE_GROUP=true to delete ${NETWORK_RESOURCE_GROUP}."
  exit 0
fi

exists="$(az group exists --name "${NETWORK_RESOURCE_GROUP}" --only-show-errors)"
if [[ "${exists}" != "true" ]]; then
  log "Network resource group ${NETWORK_RESOURCE_GROUP} does not exist"
  exit 0
fi

log "Deleting network resource group ${NETWORK_RESOURCE_GROUP}"
az group delete \
  --name "${NETWORK_RESOURCE_GROUP}" \
  --yes \
  --no-wait \
  --only-show-errors \
  >/dev/null

poll_interval=20
elapsed=0
timeout_seconds="${NETWORK_RG_WAIT_TIMEOUT:-1200}"

log "Waiting for network resource group ${NETWORK_RESOURCE_GROUP} to be deleted"
while (( elapsed < timeout_seconds )); do
  exists="$(az group exists --name "${NETWORK_RESOURCE_GROUP}" --only-show-errors)"
  if [[ "${exists}" == "false" ]]; then
    log "Network resource group ${NETWORK_RESOURCE_GROUP} deleted"
    exit 0
  fi
  sleep "${poll_interval}"
  elapsed=$((elapsed + poll_interval))
done

warn "Timed out waiting for ${NETWORK_RESOURCE_GROUP} deletion; delete may still be in progress"
