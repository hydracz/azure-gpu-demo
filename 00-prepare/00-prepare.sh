#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../common.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/scripts/prepare-acr.sh"

export SHARED_ENV_FILE="${SHARED_ENV_FILE:-${GENERATED_ENV_FILE}}"

load_env
need_cmd az
require_env AZ_SUBSCRIPTION_ID LOCATION RESOURCE_GROUP

export AZURE_SUBSCRIPTION_ID="${AZURE_SUBSCRIPTION_ID:-${AZ_SUBSCRIPTION_ID}}"

az account set --subscription "${AZ_SUBSCRIPTION_ID}" --only-show-errors >/dev/null

bash "${SCRIPT_DIR}/scripts/prepare-network.sh"
load_env

ensure_acr_ready

exec bash "${SCRIPT_DIR}/scripts/prepare-shared-assets.sh" "$@"