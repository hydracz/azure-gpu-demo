#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TERRAFORM_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../../../common.sh"

ENV_NAME="${1:-}"
OUTPUT_FILE="${2:-}"

if [[ -z "${ENV_NAME}" ]]; then
  echo "usage: ./scripts/render-tfbackend-from-env.sh <env-name> [output-file]"
  exit 1
fi

if [[ -z "${OUTPUT_FILE}" ]]; then
  OUTPUT_FILE="${TERRAFORM_DIR}/${ENV_NAME}.tfbackend"
fi

load_env
ensure_parent_dir "${OUTPUT_FILE}"

require_env TFSTATE_RESOURCE_GROUP TFSTATE_STORAGE_ACCOUNT

TFSTATE_KEY_VALUE="${TFSTATE_KEY:-azure-gpu-demo/01-environment/${ENV_NAME}.tfstate}"

cat > "${OUTPUT_FILE}" <<EOF
resource_group_name  = "${TFSTATE_RESOURCE_GROUP}"
storage_account_name = "${TFSTATE_STORAGE_ACCOUNT}"
container_name       = "${TFSTATE_CONTAINER}"
key                  = "${TFSTATE_KEY_VALUE}"
use_azuread_auth     = ${TFSTATE_USE_AZUREAD_AUTH}
EOF

echo "Rendered Terraform backend config to ${OUTPUT_FILE}"