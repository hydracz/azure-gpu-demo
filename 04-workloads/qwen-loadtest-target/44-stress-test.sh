#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QWEN_LOADTEST_TEST_MODE_OVERRIDE="${QWEN_LOADTEST_TEST_MODE:-}"
QWEN_LOADTEST_TEST_PATH_OVERRIDE="${QWEN_LOADTEST_TEST_PATH:-}"
QWEN_LOADTEST_TEST_VIA_CLUSTER_GATEWAY_OVERRIDE="${QWEN_LOADTEST_TEST_VIA_CLUSTER_GATEWAY:-}"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../../common.sh"

usage() {
  cat <<'EOF'
Usage:
  ./04-workloads/qwen-loadtest-target/44-stress-test.sh

Optional env overrides:
  QWEN_LOADTEST_STRESS_DURATION_SECONDS   default: 900
  QWEN_LOADTEST_STRESS_CONCURRENCY        default: 4
  QWEN_LOADTEST_STRESS_REQUEST_TIMEOUT    default: 900
  QWEN_LOADTEST_STRESS_STEPS              default: 6
  QWEN_LOADTEST_STRESS_CFG                default: 2.5
  QWEN_LOADTEST_STRESS_RUN_NAME           default: qwen-stress-curl
  QWEN_LOADTEST_TEST_MODE                 default: predict
  QWEN_LOADTEST_TEST_PATH                 default: /predict
  QWEN_LOADTEST_TEST_VIA_CLUSTER_GATEWAY  default: true

Examples:
  ./04-workloads/qwen-loadtest-target/44-stress-test.sh
  QWEN_LOADTEST_STRESS_DURATION_SECONDS=600 QWEN_LOADTEST_STRESS_CONCURRENCY=4 ./04-workloads/qwen-loadtest-target/44-stress-test.sh
  QWEN_LOADTEST_TEST_MODE=get QWEN_LOADTEST_TEST_PATH=/healthz QWEN_LOADTEST_STRESS_DURATION_SECONDS=60 ./04-workloads/qwen-loadtest-target/44-stress-test.sh
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

load_env
if [[ -n "${QWEN_LOADTEST_TEST_MODE_OVERRIDE}" ]]; then
  QWEN_LOADTEST_TEST_MODE="${QWEN_LOADTEST_TEST_MODE_OVERRIDE}"
fi
if [[ -n "${QWEN_LOADTEST_TEST_PATH_OVERRIDE}" ]]; then
  QWEN_LOADTEST_TEST_PATH="${QWEN_LOADTEST_TEST_PATH_OVERRIDE}"
fi
if [[ -n "${QWEN_LOADTEST_TEST_VIA_CLUSTER_GATEWAY_OVERRIDE}" ]]; then
  QWEN_LOADTEST_TEST_VIA_CLUSTER_GATEWAY="${QWEN_LOADTEST_TEST_VIA_CLUSTER_GATEWAY_OVERRIDE}"
fi

need_cmd kubectl

require_env AZ_SUBSCRIPTION_ID RESOURCE_GROUP CLUSTER_NAME

ensure_aks_kubeconfig

QWEN_LOADTEST_NAMESPACE="${QWEN_LOADTEST_NAMESPACE:-qwen-loadtest}"
QWEN_LOADTEST_NAME="${QWEN_LOADTEST_NAME:-qwen-loadtest-target}"
QWEN_LOADTEST_GATEWAY_NAME="${QWEN_LOADTEST_GATEWAY_NAME:-qwen-loadtest-external}"
QWEN_LOADTEST_TEST_MODE="${QWEN_LOADTEST_TEST_MODE:-predict}"
QWEN_LOADTEST_TEST_PATH="${QWEN_LOADTEST_TEST_PATH:-/predict}"
QWEN_LOADTEST_TEST_VIA_CLUSTER_GATEWAY="${QWEN_LOADTEST_TEST_VIA_CLUSTER_GATEWAY:-true}"
QWEN_LOADTEST_TEST_REQUEST_TIMEOUT="${QWEN_LOADTEST_TEST_REQUEST_TIMEOUT:-180}"
QWEN_LOADTEST_URL="${QWEN_LOADTEST_URL:-}"
QWEN_LOADTEST_HOST="${QWEN_LOADTEST_HOST:-}"
QWEN_LOADTEST_GATEWAY_IP="${QWEN_LOADTEST_GATEWAY_IP:-}"
QWEN_LOADTEST_GATEWAY_WORKLOAD_NAMESPACE="${QWEN_LOADTEST_GATEWAY_WORKLOAD_NAMESPACE:-${QWEN_LOADTEST_NAMESPACE}}"
QWEN_LOADTEST_GATEWAY_SELECTOR="${QWEN_LOADTEST_GATEWAY_SELECTOR:-${QWEN_LOADTEST_GATEWAY_NAME}}"
QWEN_LOADTEST_SEED_NAME="${QWEN_LOADTEST_SEED_NAME:-${QWEN_LOADTEST_NAME}-seed}"
QWEN_LOADTEST_ELASTIC_NAME="${QWEN_LOADTEST_ELASTIC_NAME:-${QWEN_LOADTEST_NAME}-elastic}"
QWEN_LOADTEST_ELASTIC_MIN_REPLICAS="${QWEN_LOADTEST_ELASTIC_MIN_REPLICAS:-0}"

QWEN_LOADTEST_STRESS_DURATION_SECONDS="${QWEN_LOADTEST_STRESS_DURATION_SECONDS:-900}"
QWEN_LOADTEST_STRESS_CONCURRENCY="${QWEN_LOADTEST_STRESS_CONCURRENCY:-4}"
QWEN_LOADTEST_STRESS_REQUEST_TIMEOUT="${QWEN_LOADTEST_STRESS_REQUEST_TIMEOUT:-900}"
QWEN_LOADTEST_STRESS_STEPS="${QWEN_LOADTEST_STRESS_STEPS:-6}"
QWEN_LOADTEST_STRESS_CFG="${QWEN_LOADTEST_STRESS_CFG:-2.5}"
QWEN_LOADTEST_STRESS_RUN_NAME="${QWEN_LOADTEST_STRESS_RUN_NAME:-qwen-stress-curl}"

refresh_qwen_loadtest_gateway_access "${QWEN_LOADTEST_GATEWAY_WORKLOAD_NAMESPACE}" "${QWEN_LOADTEST_GATEWAY_SELECTOR}" "${QWEN_LOADTEST_NAME}"

[[ -n "${QWEN_LOADTEST_URL}" ]] || fail "QWEN_LOADTEST_URL is empty. Run 41-deploy.sh first."
[[ -n "${QWEN_LOADTEST_HOST}" ]] || fail "QWEN_LOADTEST_HOST is empty. Run 41-deploy.sh first."
[[ -n "${QWEN_LOADTEST_GATEWAY_IP}" ]] || fail "QWEN_LOADTEST_GATEWAY_IP is empty. Run 41-deploy.sh first."

kubectl rollout status deployment/${QWEN_LOADTEST_SEED_NAME} -n "${QWEN_LOADTEST_NAMESPACE}" --timeout=30m >/dev/null

if (( QWEN_LOADTEST_ELASTIC_MIN_REPLICAS > 0 )); then
  kubectl rollout status deployment/${QWEN_LOADTEST_ELASTIC_NAME} -n "${QWEN_LOADTEST_NAMESPACE}" --timeout=30m >/dev/null
fi

gateway_target_ip="$(resolve_qwen_loadtest_gateway_target_ip "${QWEN_LOADTEST_GATEWAY_WORKLOAD_NAMESPACE}" "${QWEN_LOADTEST_GATEWAY_SELECTOR}" "${QWEN_LOADTEST_TEST_VIA_CLUSTER_GATEWAY}")"

[[ -n "${gateway_target_ip}" ]] || fail "Unable to resolve gateway target IP"

kubectl -n "${QWEN_LOADTEST_NAMESPACE}" delete pod "${QWEN_LOADTEST_STRESS_RUN_NAME}" --ignore-not-found >/dev/null 2>&1 || true

read -r -d '' pod_script <<'EOF' || true
now_ts() {
  date '+%Y-%m-%dT%H:%M:%S%z'
}

round=0
total_ok=0
total_busy=0
total_fail5xx=0
total_other=0
total_requests=0
end_ts=$(( $(date +%s) + TEST_DURATION_SECONDS ))

printf 'loadtest start ts=%s duration=%ss concurrency=%s mode=%s path=%s steps=%s\n' "$(now_ts)" "$TEST_DURATION_SECONDS" "$TEST_CONCURRENCY" "$TEST_MODE" "$TARGET_PATH" "$TEST_STEPS"

if [ "$TEST_MODE" = 'predict' ]; then
  cat <<'PNGEOF' | base64 -d > /tmp/tiny.png
iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+lmX0AAAAASUVORK5CYII=
PNGEOF
fi

while [ "$(date +%s)" -lt "$end_ts" ]; do
  round=$((round + 1))
  rm -f /tmp/qwen-meta-*.txt /tmp/qwen-body-*.json /tmp/qwen-curl-*.err

  req=1
  while [ "$req" -le "$TEST_CONCURRENCY" ]; do
    (
      if [ "$TEST_MODE" = 'predict' ]; then
        curl -sS --connect-timeout 10 --max-time "$REQUEST_TIMEOUT" \
          --resolve "$TARGET_HOST:443:$TARGET_IP" \
          -F image=@/tmp/tiny.png \
          -F prompt="pressure-${round}-${req}" \
          -F steps="$TEST_STEPS" \
          -F cfg="$TEST_CFG" \
          "https://$TARGET_HOST$TARGET_PATH" \
          -o "/tmp/qwen-body-${req}.json" \
          -w '%{http_code} %{time_total}' \
          > "/tmp/qwen-meta-${req}.txt" 2> "/tmp/qwen-curl-${req}.err" || printf '000 0\n' > "/tmp/qwen-meta-${req}.txt"
      else
        curl -sS --connect-timeout 10 --max-time "$REQUEST_TIMEOUT" \
          --resolve "$TARGET_HOST:443:$TARGET_IP" \
          "https://$TARGET_HOST$TARGET_PATH" \
          -o "/tmp/qwen-body-${req}.json" \
          -w '%{http_code} %{time_total}' \
          > "/tmp/qwen-meta-${req}.txt" 2> "/tmp/qwen-curl-${req}.err" || printf '000 0\n' > "/tmp/qwen-meta-${req}.txt"
      fi
    ) &
    req=$((req + 1))
  done

  wait

  ok=0
  busy=0
  fail5xx=0
  other=0
  slowest=0
  req=1
  while [ "$req" -le "$TEST_CONCURRENCY" ]; do
    if [ -f "/tmp/qwen-meta-${req}.txt" ]; then
      set -- $(cat "/tmp/qwen-meta-${req}.txt")
      code=${1:-000}
      total=${2:-0}
      if awk -v a="$total" -v b="$slowest" 'BEGIN { exit !(a > b) }'; then
        slowest="$total"
      fi

      case "$code" in
        200) ok=$((ok + 1)) ;;
        429) busy=$((busy + 1)) ;;
        5*) fail5xx=$((fail5xx + 1)) ;;
        *) other=$((other + 1)) ;;
      esac
    else
      other=$((other + 1))
    fi
    req=$((req + 1))
  done

  total_ok=$((total_ok + ok))
  total_busy=$((total_busy + busy))
  total_fail5xx=$((total_fail5xx + fail5xx))
  total_other=$((total_other + other))
  total_requests=$((total_requests + TEST_CONCURRENCY))

  printf 'ts=%s round=%s ok=%s busy=%s fail5xx=%s other=%s slowest=%ss\n' "$(now_ts)" "$round" "$ok" "$busy" "$fail5xx" "$other" "$slowest"
done

printf 'summary rounds=%s total_requests=%s ok=%s busy=%s fail5xx=%s other=%s\n' "$round" "$total_requests" "$total_ok" "$total_busy" "$total_fail5xx" "$total_other"
printf 'loadtest end ts=%s rounds=%s\n' "$(now_ts)" "$round"
EOF

log "Running ${QWEN_LOADTEST_STRESS_DURATION_SECONDS}s stress test against ${QWEN_LOADTEST_HOST}${QWEN_LOADTEST_TEST_PATH} via ${gateway_target_ip}"
log "  mode        : ${QWEN_LOADTEST_TEST_MODE}"
log "  concurrency : ${QWEN_LOADTEST_STRESS_CONCURRENCY}"
log "  timeout     : ${QWEN_LOADTEST_STRESS_REQUEST_TIMEOUT}"
if [[ "${QWEN_LOADTEST_TEST_MODE}" == "predict" ]]; then
  log "  steps/cfg   : ${QWEN_LOADTEST_STRESS_STEPS}/${QWEN_LOADTEST_STRESS_CFG}"
fi

stress_test_overrides='{"apiVersion":"v1","kind":"Pod","metadata":{"annotations":{"sidecar.istio.io/inject":"false"}}}'

kubectl -n "${QWEN_LOADTEST_NAMESPACE}" run "${QWEN_LOADTEST_STRESS_RUN_NAME}" \
  --image=curlimages/curl:8.12.1 \
  --restart=Never \
  --overrides="${stress_test_overrides}" \
  --env=TARGET_HOST="${QWEN_LOADTEST_HOST}" \
  --env=TARGET_IP="${gateway_target_ip}" \
  --env=TARGET_PATH="${QWEN_LOADTEST_TEST_PATH}" \
  --env=TEST_MODE="${QWEN_LOADTEST_TEST_MODE}" \
  --env=TEST_CONCURRENCY="${QWEN_LOADTEST_STRESS_CONCURRENCY}" \
  --env=REQUEST_TIMEOUT="${QWEN_LOADTEST_STRESS_REQUEST_TIMEOUT}" \
  --env=TEST_DURATION_SECONDS="${QWEN_LOADTEST_STRESS_DURATION_SECONDS}" \
  --env=TEST_STEPS="${QWEN_LOADTEST_STRESS_STEPS}" \
  --env=TEST_CFG="${QWEN_LOADTEST_STRESS_CFG}" \
  --attach \
  --rm \
  --command -- sh -ceu "${pod_script}"

log "Current deployment status"
kubectl -n "${QWEN_LOADTEST_NAMESPACE}" get deploy,pod,svc,hpa,scaledobject