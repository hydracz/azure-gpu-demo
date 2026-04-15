#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENVIRONMENT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

log() {
  printf '[grafana] %s\n' "$*"
}

warn() {
  printf '[grafana][warn] %s\n' "$*" >&2
}

fail() {
  printf '[grafana][error] %s\n' "$*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "missing required command: $1"
}

require_env() {
  local name
  for name in "$@"; do
    [[ -n "${!name:-}" ]] || fail "${name} is required"
  done
}

ensure_amg_extension() {
  if az extension show --name amg --only-show-errors >/dev/null 2>&1; then
    return 0
  fi

  log "Installing Azure CLI extension amg"
  az extension add --name amg --only-show-errors >/dev/null
}

dashboard_title() {
  python3 - "$1" <<'PY'
import json
import sys

with open(sys.argv[1], 'r', encoding='utf-8') as handle:
    payload = json.load(handle)

print(payload.get('title', sys.argv[1]))
PY
}

render_create_payload() {
  python3 - "$1" "$2" <<'PY'
import json
import sys

source_path, output_path = sys.argv[1], sys.argv[2]
with open(source_path, 'r', encoding='utf-8') as handle:
    dashboard = json.load(handle)

dashboard.pop('id', None)
dashboard.pop('meta', None)

payload = {
    'dashboard': dashboard,
    'overwrite': True,
    'message': 'Managed by azure-gpu-demo',
}

with open(output_path, 'w', encoding='utf-8') as handle:
    json.dump(payload, handle, ensure_ascii=False)
PY
}

list_dashboard_files() {
  local file
  local -a files=()

  if [[ -d "${ENVIRONMENT_DIR}/grafana/dashboards" ]]; then
    while IFS= read -r file; do
      files+=("${file}")
    done < <(find "${ENVIRONMENT_DIR}/grafana/dashboards" -maxdepth 1 -type f -name '*.json' | sort)
  fi

  if [[ ${#files[@]} -eq 0 ]]; then
    fail "No dashboard JSON files found under ${ENVIRONMENT_DIR}"
  fi

  printf '%s\n' "${files[@]}"
}

need_cmd az
need_cmd python3

require_env AZURE_SUBSCRIPTION_ID RESOURCE_GROUP GRAFANA_NAME

az account set --subscription "${AZURE_SUBSCRIPTION_ID}" --only-show-errors >/dev/null
ensure_amg_extension

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

while IFS= read -r dashboard_file; do
  [[ -f "${dashboard_file}" ]] || fail "Dashboard file not found: ${dashboard_file}"

  title="$(dashboard_title "${dashboard_file}")"
  payload_file="${tmp_dir}/$(basename "${dashboard_file}")"
  render_create_payload "${dashboard_file}" "${payload_file}"

  log "Importing dashboard: ${title}"

  az grafana dashboard create \
    --name "${GRAFANA_NAME}" \
    --resource-group "${RESOURCE_GROUP}" \
    --title "${title}" \
    --overwrite true \
    --definition "@${payload_file}" \
    --only-show-errors \
    >/dev/null
done < <(list_dashboard_files)

log "Managed Grafana dashboards currently available:"
az grafana dashboard list \
  --name "${GRAFANA_NAME}" \
  --resource-group "${RESOURCE_GROUP}" \
  --query "[].title" \
  -o tsv \
  --only-show-errors