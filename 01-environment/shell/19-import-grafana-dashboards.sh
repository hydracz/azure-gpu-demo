#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../../common.sh"

load_env
need_cmd az
need_cmd python3

: "${GRAFANA_DASHBOARD_IMPORT_ENABLED:=true}"

if [[ "${GRAFANA_DASHBOARD_IMPORT_ENABLED}" != "true" ]]; then
  log "GRAFANA_DASHBOARD_IMPORT_ENABLED=false, skipping dashboard import"
  exit 0
fi

if [[ -z "${GRAFANA_NAME:-}" && -n "${GRAFANA_ID:-}" ]]; then
  GRAFANA_NAME="${GRAFANA_ID##*/}"
fi

require_env AZ_SUBSCRIPTION_ID RESOURCE_GROUP GRAFANA_NAME

AZURE_SUBSCRIPTION_ID="${AZ_SUBSCRIPTION_ID}" \
RESOURCE_GROUP="${RESOURCE_GROUP}" \
GRAFANA_NAME="${GRAFANA_NAME}" \
  bash "${SCRIPT_DIR}/../scripts/import-grafana-dashboards.sh"