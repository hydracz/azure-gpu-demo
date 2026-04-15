#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_NAME="${1:-}"

if [[ -z "${ENV_NAME}" ]]; then
  echo "usage: ./00-init.sh <env-name>"
  exit 1
fi

command -v terraform >/dev/null 2>&1 || {
  echo "terraform is required but not installed"
  exit 1
}

BACKEND_FILE="${SCRIPT_DIR}/${ENV_NAME}.tfbackend"

bash "${SCRIPT_DIR}/scripts/render-tfbackend-from-env.sh" "${ENV_NAME}" "${BACKEND_FILE}"

cd "${SCRIPT_DIR}"
terraform init -backend-config="${BACKEND_FILE}"