#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
SHARED_ENV_FILE="${SHARED_ENV_FILE:-${REPO_ROOT}/.generated.env}"

# shellcheck disable=SC1091
source "${REPO_ROOT}/01-environment/terraform/scripts/common.sh"

write_generated_env() {
  local key="$1"
  local value="$2"

  mkdir -p "$(dirname "${SHARED_ENV_FILE}")"
  touch "${SHARED_ENV_FILE}"

  python3 - "${SHARED_ENV_FILE}" "${key}" "${value}" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
key = sys.argv[2]
value = sys.argv[3]

def shell_double_quote(raw: str) -> str:
    return raw.replace('\\', '\\\\').replace('"', '\\"').replace('$', '\\$').replace('`', '\\`')

new_line = f'{key}="{shell_double_quote(value)}"'
lines = path.read_text(encoding='utf-8').splitlines() if path.exists() else []

for index, line in enumerate(lines):
    if line.startswith(f"{key}="):
        lines[index] = new_line
        break
else:
    lines.append(new_line)

path.write_text("\n".join(lines) + "\n", encoding='utf-8')
PY
}

# shellcheck disable=SC1091
source "${SCRIPT_DIR}/image-sync-lib.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/karpenter-image-sync.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/gpu-operator-image-sync.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/kiali-image-sync.sh"

image_sync_require_backend_tools

for required_var in \
  AZURE_SUBSCRIPTION_ID RESOURCE_GROUP ACR_NAME EXISTING_VNET_SUBNET_ID \
  KARPENTER_IMAGE_REPOSITORY KARPENTER_IMAGE_TAG \
  GPU_DRIVER_SOURCE_REPOSITORY GPU_DRIVER_IMAGE GPU_DRIVER_VERSION \
  GPU_DRIVER_SYNC_ENABLED GPU_DRIVER_VERSION_SOURCE_TAG_2204 GPU_DRIVER_VERSION_SOURCE_TAG_2404 \
  ISTIO_KIALI_ENABLED ISTIO_KIALI_OPERATOR_CHART_VERSION
do
  [[ -n "${!required_var:-}" ]] || fail "${required_var} is required"
done

if ! az network vnet subnet show --ids "${EXISTING_VNET_SUBNET_ID}" --only-show-errors >/dev/null 2>&1; then
  fail "Subnet ${EXISTING_VNET_SUBNET_ID} was not found while preparing shared assets"
fi

image_sync_write_env_if_available EXISTING_VNET_SUBNET_ID "${EXISTING_VNET_SUBNET_ID}"
image_sync_write_env_if_available AKS_SUBNET_ID "${EXISTING_VNET_SUBNET_ID}"

log "Preparing shared Azure assets"
log "  subnet id : ${EXISTING_VNET_SUBNET_ID}"
log "  acr name  : ${ACR_NAME}"
log "  sync tool : $(image_sync_selected_tool)"

sync_karpenter_image
sync_gpu_operator_images

if [[ "${ISTIO_KIALI_ENABLED}" == "true" ]]; then
  sync_kiali_images
fi

log "Shared asset preparation completed"
log "  shared env file              : ${SHARED_ENV_FILE}"
log "  ACR login server             : ${ACR_LOGIN_SERVER}"
log "  Karpenter target repository  : ${KARPENTER_TARGET_IMAGE_REPOSITORY}"
log "  GPU driver target repository : ${GPU_DRIVER_TARGET_REPOSITORY}"
if [[ -n "${ISTIO_KIALI_OPERATOR_TARGET_IMAGE_REPOSITORY:-}" ]]; then
  log "  Kiali operator target repo   : ${ISTIO_KIALI_OPERATOR_TARGET_IMAGE_REPOSITORY}"
  log "  Kiali target image           : ${ISTIO_KIALI_TARGET_IMAGE_NAME}:${ISTIO_KIALI_IMAGE_TAG}"
fi