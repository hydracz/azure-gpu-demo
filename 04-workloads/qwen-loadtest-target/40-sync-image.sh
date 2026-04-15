#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../../common.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../../01-environment/scripts/image-sync-lib.sh"

load_env
need_cmd az

QWEN_LOADTEST_SOURCE_LOGIN_SERVER="${QWEN_LOADTEST_SOURCE_LOGIN_SERVER:-qwenloadtestsea3414.azurecr.io}"
QWEN_LOADTEST_SOURCE_IMAGE_REPOSITORY="${QWEN_LOADTEST_SOURCE_IMAGE_REPOSITORY:-qwen-loadtest-target}"
QWEN_LOADTEST_SOURCE_IMAGE_TAG="${QWEN_LOADTEST_SOURCE_IMAGE_TAG:-sea-a100-failfast-20260413}"
QWEN_LOADTEST_SOURCE_USERNAME="${QWEN_LOADTEST_SOURCE_USERNAME:-${QWEN_LOADTEST_SOURCE_LOGIN_SERVER%%.*}}"
QWEN_LOADTEST_TARGET_REPOSITORY="${QWEN_LOADTEST_TARGET_REPOSITORY:-aks/qwen-loadtest-target}"

require_env AZ_SUBSCRIPTION_ID RESOURCE_GROUP ACR_NAME

export AZURE_SUBSCRIPTION_ID="${AZ_SUBSCRIPTION_ID}"
az account set --subscription "${AZ_SUBSCRIPTION_ID}" --only-show-errors >/dev/null

image_sync_ensure_acr_login_server

source_ref="${QWEN_LOADTEST_SOURCE_LOGIN_SERVER}/${QWEN_LOADTEST_SOURCE_IMAGE_REPOSITORY}:${QWEN_LOADTEST_SOURCE_IMAGE_TAG}"
target_ref="${QWEN_LOADTEST_TARGET_REPOSITORY}:${QWEN_LOADTEST_SOURCE_IMAGE_TAG}"
target_image="${ACR_LOGIN_SERVER}/${target_ref}"

target_tag_exists() {
  az acr repository show-tags \
    --name "${ACR_NAME}" \
    --repository "${QWEN_LOADTEST_TARGET_REPOSITORY}" \
    --query "contains(@, '${QWEN_LOADTEST_SOURCE_IMAGE_TAG}')" \
    -o tsv \
    --only-show-errors 2>/dev/null | grep -qx true
}

log "Qwen loadtest image mirror plan:"
log "  source image : ${source_ref}"
log "  target image : ${target_image}"

if target_tag_exists; then
  log "Target image already exists in ${ACR_NAME}, skipping import"
elif [[ -z "${QWEN_LOADTEST_SOURCE_PASSWORD:-}" ]]; then
  fail "QWEN_LOADTEST_SOURCE_PASSWORD is required when target image ${target_image} is not already present in ${ACR_NAME}"
else
  az acr import \
    --name "${ACR_NAME}" \
    --resource-group "${RESOURCE_GROUP}" \
    --source "${source_ref}" \
    --username "${QWEN_LOADTEST_SOURCE_USERNAME}" \
    --password "${QWEN_LOADTEST_SOURCE_PASSWORD}" \
    --image "${target_ref}" \
    --force \
    --only-show-errors >/dev/null
fi

write_generated_env QWEN_LOADTEST_SOURCE_IMAGE "${source_ref}"
write_generated_env QWEN_LOADTEST_TARGET_IMAGE "${target_image}"
write_generated_env QWEN_LOADTEST_TARGET_REPOSITORY "${QWEN_LOADTEST_TARGET_REPOSITORY}"

log "Mirror completed"
log "  target image : ${target_image}"