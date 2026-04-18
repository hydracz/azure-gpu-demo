#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 20-build-test-image.sh  —  构建并推送 GPU 探测镜像到 ACR
# ---------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../../common.sh"

load_env
ensure_tooling

: "${TEST_IMAGE_REPOSITORY:=aks/gpu-probe}"
: "${TEST_IMAGE_TAG:=latest}"

require_env AZ_SUBSCRIPTION_ID RESOURCE_GROUP ACR_NAME TEST_IMAGE_REPOSITORY TEST_IMAGE_TAG

az account set --subscription "${AZ_SUBSCRIPTION_ID}" --only-show-errors

image_ref="${TEST_IMAGE_REPOSITORY}:${TEST_IMAGE_TAG}"
acr_name="${ACR_NAME}"
acr_resource_group="${ACR_RESOURCE_GROUP:-${RESOURCE_GROUP}}"

if [[ -n "${EXISTING_ACR_ID:-}" ]]; then
  acr_name="$(printf '%s' "${EXISTING_ACR_ID}" | awk -F/ 'NF >= 9 {print $9}')"
  [[ -n "${acr_name}" ]] || fail "Unable to parse ACR name from EXISTING_ACR_ID=${EXISTING_ACR_ID}"
fi

login_server="$(az acr show --name "${acr_name}" --resource-group "${acr_resource_group}" --query loginServer -o tsv --only-show-errors)"
full_image_uri="${login_server}/${image_ref}"

log "Building and pushing ${full_image_uri} through ACR Tasks"
az acr build \
  --registry "${acr_name}" \
  --image "${image_ref}" \
  "${SCRIPT_DIR}/test-app" \
  --only-show-errors

write_generated_env TEST_IMAGE_URI "${full_image_uri}"
write_generated_env TEST_IMAGE_ACR_LOGIN_SERVER "${login_server}"
write_generated_env TEST_IMAGE_REPOSITORY_PATH "${TEST_IMAGE_REPOSITORY}"

log "Image published: ${full_image_uri}"
