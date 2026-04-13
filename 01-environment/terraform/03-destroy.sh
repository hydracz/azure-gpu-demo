#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_NAME="${1:-}"

if [[ -z "${ENV_NAME}" ]]; then
  echo "usage: ./03-destroy.sh <env-name>"
  exit 1
fi

command -v terraform >/dev/null 2>&1 || {
  echo "terraform is required but not installed"
  exit 1
}

VAR_FILE="${SCRIPT_DIR}/${ENV_NAME}.tfvar"

if [[ ! -f "${VAR_FILE}" ]]; then
  echo "missing tfvar file: ${VAR_FILE}"
  exit 1
fi

cd "${SCRIPT_DIR}"
terraform validate
terraform destroy -var-file="${VAR_FILE}"