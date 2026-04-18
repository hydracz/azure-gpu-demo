#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../common.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/scripts/prepare-acr.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/scripts/image-sync-lib.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/scripts/dragonfly-image-sync.sh"

IMAGE_SYNC_TOOL_OVERRIDE="${IMAGE_SYNC_TOOL:-}"

load_env
: "${DRAGONFLY_ENABLED:=true}"

if [[ -n "${IMAGE_SYNC_TOOL_OVERRIDE}" ]]; then
  export IMAGE_SYNC_TOOL="${IMAGE_SYNC_TOOL_OVERRIDE}"
fi

need_cmd az
require_env AZ_SUBSCRIPTION_ID LOCATION RESOURCE_GROUP

az account set --subscription "${AZ_SUBSCRIPTION_ID}" --only-show-errors >/dev/null
ensure_acr_ready

if [[ "${DRAGONFLY_ENABLED}" != "true" ]]; then
  log "DRAGONFLY_ENABLED=${DRAGONFLY_ENABLED}; skip Dragonfly image sync"
  exit 0
fi

sync_dragonfly_images