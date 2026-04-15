#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../common.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/scripts/prepare-acr.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/scripts/image-sync-lib.sh"
QWEN_LOADTEST_SOURCE_LOGIN_SERVER="${QWEN_LOADTEST_SOURCE_LOGIN_SERVER:-qwenloadtestsea3414.azurecr.io}"
QWEN_LOADTEST_SOURCE_IMAGE_REPOSITORY="${QWEN_LOADTEST_SOURCE_IMAGE_REPOSITORY:-qwen-loadtest-target}"
QWEN_LOADTEST_SOURCE_IMAGE_TAG="${QWEN_LOADTEST_SOURCE_IMAGE_TAG:-sea-a100-failfast-20260413}"
QWEN_LOADTEST_SOURCE_USERNAME="${QWEN_LOADTEST_SOURCE_USERNAME:-${QWEN_LOADTEST_SOURCE_LOGIN_SERVER%%.*}}"
QWEN_LOADTEST_TARGET_REPOSITORY="${QWEN_LOADTEST_TARGET_REPOSITORY:-aks/qwen-loadtest-target}"
QWEN_LOADTEST_IMPORT_NO_WAIT="${QWEN_LOADTEST_IMPORT_NO_WAIT:-true}"

sync_qwen_image() {
  local source_ref="${QWEN_LOADTEST_SOURCE_LOGIN_SERVER}/${QWEN_LOADTEST_SOURCE_IMAGE_REPOSITORY}:${QWEN_LOADTEST_SOURCE_IMAGE_TAG}"
  local target_ref="${QWEN_LOADTEST_TARGET_REPOSITORY}:${QWEN_LOADTEST_SOURCE_IMAGE_TAG}"
  local target_image="${ACR_LOGIN_SERVER}/${target_ref}"

  image_sync_require_backend_tools
  image_sync_ensure_acr_login_server

  log "Qwen image sync plan:"
  log "  source image : ${source_ref}"
  log "  target image : ${target_image}"
  log "  sync tool    : $(image_sync_selected_tool)"

  write_generated_env QWEN_LOADTEST_SOURCE_IMAGE "${source_ref}"
  write_generated_env QWEN_LOADTEST_TARGET_IMAGE "${target_image}"
  write_generated_env QWEN_LOADTEST_TARGET_REPOSITORY "${QWEN_LOADTEST_TARGET_REPOSITORY}"

  IMAGE_SYNC_AZ_ACR_IMPORT_NO_WAIT="${QWEN_LOADTEST_IMPORT_NO_WAIT}"
  export IMAGE_SYNC_AZ_ACR_IMPORT_NO_WAIT
  image_sync_import_ref "${source_ref}" "${target_ref}" "${QWEN_LOADTEST_SOURCE_USERNAME}" "${QWEN_LOADTEST_SOURCE_PASSWORD:-}"

  log "Qwen image sync completed"
  log "  target image : ${target_image}"
}

load_env
need_cmd az
require_env AZ_SUBSCRIPTION_ID LOCATION RESOURCE_GROUP QWEN_LOADTEST_SOURCE_LOGIN_SERVER QWEN_LOADTEST_SOURCE_IMAGE_REPOSITORY QWEN_LOADTEST_SOURCE_IMAGE_TAG QWEN_LOADTEST_TARGET_REPOSITORY

az account set --subscription "${AZ_SUBSCRIPTION_ID}" --only-show-errors >/dev/null
ensure_acr_ready
sync_qwen_image