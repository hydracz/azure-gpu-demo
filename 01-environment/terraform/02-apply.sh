#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../../common.sh"
INPUT_ARG="${1:-}"

if [[ -z "${INPUT_ARG}" ]]; then
  echo "usage: ./02-apply.sh <env-name|plan-file>"
  exit 1
fi

command -v terraform >/dev/null 2>&1 || {
  echo "terraform is required but not installed"
  exit 1
}

if [[ "${INPUT_ARG}" == *.tfplan ]]; then
  if [[ "${INPUT_ARG}" = /* ]]; then
    PLAN_FILE="${INPUT_ARG}"
  else
    PLAN_FILE="$(pwd)/${INPUT_ARG}"
  fi
else
  PLAN_FILE="${SCRIPT_DIR}/${INPUT_ARG}.tfplan"
fi

if [[ ! -f "${PLAN_FILE}" ]]; then
  echo "missing plan file: ${PLAN_FILE}"
  if [[ "${INPUT_ARG}" == *.tfplan ]]; then
    echo "pass an existing .tfplan file path or run ./01-plan.sh <env-name> first"
  else
    echo "run ./01-plan.sh ${INPUT_ARG} first"
  fi
  exit 1
fi

cd "${SCRIPT_DIR}"
terraform apply -parallelism="${TF_APPLY_PARALLELISM:-1}" "${PLAN_FILE}"
bash "${SCRIPT_DIR}/scripts/export-generated-env.sh"