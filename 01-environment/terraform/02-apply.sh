#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_NAME="${1:-}"

if [[ -z "${ENV_NAME}" ]]; then
  echo "usage: ./02-apply.sh <env-name>"
  exit 1
fi

command -v terraform >/dev/null 2>&1 || {
  echo "terraform is required but not installed"
  exit 1
}

PLAN_FILE="${SCRIPT_DIR}/${ENV_NAME}.tfplan"

if [[ ! -f "${PLAN_FILE}" ]]; then
  echo "missing plan file: ${PLAN_FILE}"
  echo "run ./01-plan.sh ${ENV_NAME} first"
  exit 1
fi

cd "${SCRIPT_DIR}"
terraform apply "${PLAN_FILE}"