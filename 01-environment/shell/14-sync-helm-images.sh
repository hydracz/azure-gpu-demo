#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../../common.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../scripts/image-sync-lib.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../scripts/karpenter-image-sync.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../scripts/gpu-operator-image-sync.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../scripts/kiali-image-sync.sh"

load_env
need_cmd az

require_env AZ_SUBSCRIPTION_ID RESOURCE_GROUP ACR_NAME KARPENTER_IMAGE_REPO KARPENTER_IMAGE_TAG

export AZURE_SUBSCRIPTION_ID="${AZ_SUBSCRIPTION_ID}"

log "Mirroring user-managed Helm images into ${ACR_NAME}"
sync_karpenter_image
sync_gpu_operator_images

if [[ "${ISTIO_KIALI_ENABLED:-false}" == "true" ]]; then
  sync_kiali_images
fi

log "Image sync completed"
log "  ACR login server              : ${ACR_LOGIN_SERVER}"
log "  Karpenter target repository   : ${KARPENTER_TARGET_IMAGE_REPOSITORY}"
log "  GPU driver target repository  : ${GPU_DRIVER_TARGET_REPOSITORY}"
if [[ -n "${ISTIO_KIALI_OPERATOR_TARGET_IMAGE_REPOSITORY:-}" ]]; then
  log "  Kiali operator target repo    : ${ISTIO_KIALI_OPERATOR_TARGET_IMAGE_REPOSITORY}"
  log "  Kiali target image            : ${ISTIO_KIALI_TARGET_IMAGE_NAME}:${ISTIO_KIALI_IMAGE_TAG}"
fi
log "  Generated env file            : ${GENERATED_ENV_FILE}"