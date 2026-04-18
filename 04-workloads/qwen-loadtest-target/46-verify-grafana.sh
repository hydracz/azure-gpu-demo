#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../../common.sh"

load_env
need_cmd az
need_cmd curl
need_cmd python3

require_env AZ_SUBSCRIPTION_ID RESOURCE_GROUP GRAFANA_NAME MONITOR_WORKSPACE_QUERY_ENDPOINT CLUSTER_NAME

ensure_amg_extension() {
  if az extension show --name amg --only-show-errors >/dev/null 2>&1; then
    return 0
  fi

  log "Installing Azure CLI extension amg"
  az extension add --name amg --only-show-errors >/dev/null
}

QWEN_SCALE_TEST_OUTPUT_DIR="${QWEN_SCALE_TEST_OUTPUT_DIR:-${ROOT_DIR}/test-results/qwen-scale/manual}"
QWEN_SCALE_TEST_QUERY_WINDOW="${QWEN_SCALE_TEST_QUERY_WINDOW:-90m}"
QWEN_SCALE_TEST_QUERY_RETRIES="${QWEN_SCALE_TEST_QUERY_RETRIES:-20}"
QWEN_SCALE_TEST_QUERY_RETRY_DELAY_SECONDS="${QWEN_SCALE_TEST_QUERY_RETRY_DELAY_SECONDS:-15}"
mkdir -p "${QWEN_SCALE_TEST_OUTPUT_DIR}"

az account set --subscription "${AZ_SUBSCRIPTION_ID}" --only-show-errors >/dev/null
ensure_amg_extension

dashboards_json="${QWEN_SCALE_TEST_OUTPUT_DIR}/grafana-dashboards.json"
az grafana dashboard list \
  --name "${GRAFANA_NAME}" \
  --resource-group "${RESOURCE_GROUP}" \
  -o json \
  --only-show-errors >"${dashboards_json}"

monitor_token="$(az account get-access-token --resource https://prometheus.monitor.azure.com --query accessToken -o tsv --only-show-errors)"

run_query() {
  local name="$1"
  local query="$2"
  local encoded
  local output_file="${QWEN_SCALE_TEST_OUTPUT_DIR}/${name}.json"
  local attempt
  encoded="$(python3 - <<'PY' "$query"
import sys
from urllib.parse import quote_plus

print(quote_plus(sys.argv[1]))
PY
)"

  for attempt in $(seq 1 "${QWEN_SCALE_TEST_QUERY_RETRIES}"); do
    curl -fsS \
      -H "Authorization: Bearer ${monitor_token}" \
      "${MONITOR_WORKSPACE_QUERY_ENDPOINT}/api/v1/query?query=${encoded}" \
      >"${output_file}"

    if python3 - <<'PY' "$output_file" "$name"
import json
import sys

payload_path = sys.argv[1]
query_name = sys.argv[2]

with open(payload_path, 'r', encoding='utf-8') as handle:
    payload = json.load(handle)

result = ((payload.get('data') or {}).get('result')) or []
if not result:
    raise SystemExit(f'{query_name} returned no data')
PY
    then
      return 0
    fi

    if [[ "${attempt}" == "${QWEN_SCALE_TEST_QUERY_RETRIES}" ]]; then
      fail "${name} returned no data after ${QWEN_SCALE_TEST_QUERY_RETRIES} attempts"
    fi

    warn "${name} returned no data yet; retrying (${attempt}/${QWEN_SCALE_TEST_QUERY_RETRIES})"
    sleep "${QWEN_SCALE_TEST_QUERY_RETRY_DELAY_SECONDS}"
  done
}

run_query "grafana-istio-requests" "sum(increase(istio_requests_total{cluster=~\"${CLUSTER_NAME}\",reporter=\"source\",destination_workload_namespace=\"qwen-loadtest\",destination_service_name=\"qwen-loadtest-target\",gateway_networking_k8s_io_gateway_name=~\"qwen-loadtest-.*\"}[${QWEN_SCALE_TEST_QUERY_WINDOW}]))"
run_query "grafana-istio-latency" "sum(increase(istio_request_duration_milliseconds_sum{cluster=~\"${CLUSTER_NAME}\",reporter=\"source\",destination_workload_namespace=\"qwen-loadtest\",destination_service_name=\"qwen-loadtest-target\",gateway_networking_k8s_io_gateway_name=~\"qwen-loadtest-.*\"}[${QWEN_SCALE_TEST_QUERY_WINDOW}])) / clamp_min(sum(increase(istio_request_duration_milliseconds_count{cluster=~\"${CLUSTER_NAME}\",reporter=\"source\",destination_workload_namespace=\"qwen-loadtest\",destination_service_name=\"qwen-loadtest-target\",gateway_networking_k8s_io_gateway_name=~\"qwen-loadtest-.*\"}[${QWEN_SCALE_TEST_QUERY_WINDOW}])), 1)"
run_query "grafana-gpu-util" "max(avg_over_time(DCGM_FI_PROF_PIPE_TENSOR_ACTIVE{cluster=~\"${CLUSTER_NAME}\",exported_namespace=\"qwen-loadtest\"}[${QWEN_SCALE_TEST_QUERY_WINDOW}])) * 100"
run_query "grafana-gpu-visible" "count(count by (hostname, gpu) (DCGM_FI_DEV_SM_CLOCK{cluster=~\"${CLUSTER_NAME}\",exported_namespace=\"qwen-loadtest\"}))"

log "Grafana dashboards and Prometheus queries verified. Results stored in ${QWEN_SCALE_TEST_OUTPUT_DIR}"