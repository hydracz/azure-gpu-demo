#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../../common.sh"

load_env
need_cmd python3

QWEN_SCALE_TEST_OUTPUT_DIR="${QWEN_SCALE_TEST_OUTPUT_DIR:-}"
[[ -n "${QWEN_SCALE_TEST_OUTPUT_DIR}" ]] || fail "QWEN_SCALE_TEST_OUTPUT_DIR is required"

python3 "${SCRIPT_DIR}/scripts/generate-scale-report.py" --output-dir "${QWEN_SCALE_TEST_OUTPUT_DIR}"