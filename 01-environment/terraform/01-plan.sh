#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../../common.sh"
ENV_NAME="${1:-}"

if [[ -z "${ENV_NAME}" ]]; then
  echo "usage: ./01-plan.sh <env-name>"
  exit 1
fi

command -v terraform >/dev/null 2>&1 || {
  echo "terraform is required but not installed"
  exit 1
}

VAR_FILE="${SCRIPT_DIR}/${ENV_NAME}.tfvar"
AUTO_VAR_FILE="${SCRIPT_DIR}/${ENV_NAME}.auto.tfvars.json"
PLAN_FILE="${SCRIPT_DIR}/${ENV_NAME}.tfplan"

if [[ ! -f "${VAR_FILE}" ]]; then
  bash "${SCRIPT_DIR}/scripts/render-tfvars-from-env.sh" "${ENV_NAME}" "${AUTO_VAR_FILE}"
  VAR_FILE="${AUTO_VAR_FILE}"
fi

cd "${SCRIPT_DIR}"
terraform fmt -check
terraform validate
terraform plan -var-file="${VAR_FILE}" -out="${PLAN_FILE}"