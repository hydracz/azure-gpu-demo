#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../../common.sh"
ENV_NAME="${1:-}"

if [[ -z "${ENV_NAME}" ]]; then
  echo "usage: ./03-destroy.sh <env-name>"
  exit 1
fi

command -v terraform >/dev/null 2>&1 || {
  echo "terraform is required but not installed"
  exit 1
}

AUTO_VAR_FILE="${SCRIPT_DIR}/${ENV_NAME}.auto.tfvars.json"

bash "${SCRIPT_DIR}/scripts/render-tfvars-from-env.sh" "${ENV_NAME}" "${AUTO_VAR_FILE}"
bash "${SCRIPT_DIR}/scripts/ensure-azurerm-backend-access.sh" "03-destroy.sh ${ENV_NAME}"

cd "${SCRIPT_DIR}"
terraform validate
terraform destroy -var-file="${AUTO_VAR_FILE}"