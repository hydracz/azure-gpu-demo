#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QWEN_LOADTEST_TEST_MODE_OVERRIDE="${QWEN_LOADTEST_TEST_MODE:-}"
QWEN_LOADTEST_TEST_PATH_OVERRIDE="${QWEN_LOADTEST_TEST_PATH:-}"
QWEN_LOADTEST_TEST_VIA_CLUSTER_GATEWAY_OVERRIDE="${QWEN_LOADTEST_TEST_VIA_CLUSTER_GATEWAY:-}"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../../common.sh"

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
need_cmd curl
need_cmd kubectl

require_env AZ_SUBSCRIPTION_ID RESOURCE_GROUP CLUSTER_NAME

ensure_aks_kubeconfig

QWEN_LOADTEST_NAMESPACE="${QWEN_LOADTEST_NAMESPACE:-qwen-loadtest}"
QWEN_LOADTEST_NAME="${QWEN_LOADTEST_NAME:-qwen-loadtest-target}"
QWEN_LOADTEST_SERVICE_NAME="${QWEN_LOADTEST_SERVICE_NAME:-${QWEN_LOADTEST_NAME}}"
QWEN_LOADTEST_TEST_MODE="${QWEN_LOADTEST_TEST_MODE:-predict}"
QWEN_LOADTEST_TEST_PATH="${QWEN_LOADTEST_TEST_PATH:-/predict}"
QWEN_LOADTEST_TEST_VIA_CLUSTER_GATEWAY="${QWEN_LOADTEST_TEST_VIA_CLUSTER_GATEWAY:-true}"
QWEN_LOADTEST_TEST_CONCURRENCY="${QWEN_LOADTEST_TEST_CONCURRENCY:-2}"
QWEN_LOADTEST_TEST_REQUEST_TIMEOUT="${QWEN_LOADTEST_TEST_REQUEST_TIMEOUT:-180}"
QWEN_LOADTEST_URL="${QWEN_LOADTEST_URL:-}"
QWEN_LOADTEST_HOST="${QWEN_LOADTEST_HOST:-}"
QWEN_LOADTEST_GATEWAY_IP="${QWEN_LOADTEST_GATEWAY_IP:-}"
QWEN_LOADTEST_GATEWAY_WORKLOAD_NAMESPACE="${QWEN_LOADTEST_GATEWAY_WORKLOAD_NAMESPACE:-${QWEN_LOADTEST_NAMESPACE}}"
QWEN_LOADTEST_GATEWAY_SELECTOR="${QWEN_LOADTEST_GATEWAY_SELECTOR:-qwen-loadtest-external}"
QWEN_LOADTEST_CERTIFICATE_NAME="${QWEN_LOADTEST_CERTIFICATE_NAME:-${QWEN_LOADTEST_TLS_SECRET_NAME:-qwen-loadtest-target-tls}}"

if [[ "${QWEN_LOADTEST_GATEWAY_WORKLOAD_NAMESPACE}" == "aks-istio-ingress" ]]; then
  QWEN_LOADTEST_GATEWAY_WORKLOAD_NAMESPACE="${QWEN_LOADTEST_NAMESPACE}"
fi

if [[ "${QWEN_LOADTEST_GATEWAY_SELECTOR}" == "aks-istio-ingressgateway-external" ]]; then
  QWEN_LOADTEST_GATEWAY_SELECTOR="qwen-loadtest-external"
fi

if [[ "${QWEN_LOADTEST_CERTIFICATE_NAME}" == "${QWEN_LOADTEST_NAME}" ]]; then
  QWEN_LOADTEST_CERTIFICATE_NAME="${QWEN_LOADTEST_TLS_SECRET_NAME:-qwen-loadtest-target-tls}"
fi

[[ -n "${QWEN_LOADTEST_URL}" ]] || fail "QWEN_LOADTEST_URL is empty. Run 41-deploy.sh first."
[[ -n "${QWEN_LOADTEST_HOST}" ]] || fail "QWEN_LOADTEST_HOST is empty. Run 41-deploy.sh first."
[[ -n "${QWEN_LOADTEST_GATEWAY_IP}" ]] || fail "QWEN_LOADTEST_GATEWAY_IP is empty. Run 41-deploy.sh first."

kubectl rollout status deployment/${QWEN_LOADTEST_NAME} -n "${QWEN_LOADTEST_NAMESPACE}" --timeout=30m >/dev/null

if [[ "${QWEN_LOADTEST_TEST_VIA_CLUSTER_GATEWAY}" == "true" ]]; then
  gateway_target_ip="$(kubectl -n "${QWEN_LOADTEST_GATEWAY_WORKLOAD_NAMESPACE}" get svc "${QWEN_LOADTEST_GATEWAY_SELECTOR}" -o jsonpath='{.spec.clusterIP}')"
else
  gateway_target_ip="${QWEN_LOADTEST_GATEWAY_IP}"
fi

[[ -n "${gateway_target_ip}" ]] || fail "Unable to resolve gateway target IP"

log "Sending ${QWEN_LOADTEST_TEST_CONCURRENCY} concurrent HTTPS requests to ${QWEN_LOADTEST_HOST}${QWEN_LOADTEST_TEST_PATH} via ${gateway_target_ip}"

if [[ "${QWEN_LOADTEST_TEST_MODE}" == "predict" ]]; then
  smoke_test_overrides='{"apiVersion":"v1","kind":"Pod","metadata":{"annotations":{"sidecar.istio.io/inject":"false"}}}'

  kubectl -n "${QWEN_LOADTEST_NAMESPACE}" run qwen-smoke-curl \
    --image=curlimages/curl:8.12.1 \
    --restart=Never \
    --overrides="${smoke_test_overrides}" \
    --env=TARGET_HOST=${QWEN_LOADTEST_HOST} \
    --env=TARGET_IP=${gateway_target_ip} \
    --env=TARGET_PATH=${QWEN_LOADTEST_TEST_PATH} \
    --env=TEST_CONCURRENCY=${QWEN_LOADTEST_TEST_CONCURRENCY} \
    --env=REQUEST_TIMEOUT=${QWEN_LOADTEST_TEST_REQUEST_TIMEOUT} \
    --attach \
    --rm \
    --command -- sh -ceu 'cat <<"EOF" | base64 -d > /tmp/tiny.png
iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+lmX0AAAAASUVORK5CYII=
EOF
rm -f /tmp/resp-*.json /tmp/meta-*.txt
for req in $(seq 1 "$TEST_CONCURRENCY"); do
  (
    if curl -sS --connect-timeout 10 --max-time "$REQUEST_TIMEOUT" \
      --resolve "$TARGET_HOST:443:$TARGET_IP" \
      -F image=@/tmp/tiny.png \
      -F prompt="smoke-test-${req}" \
      -F steps=6 \
      -F cfg=2.5 \
      "https://$TARGET_HOST$TARGET_PATH" \
      -o "/tmp/resp-${req}.json" \
      -w "request=${req} status=%{http_code} total=%{time_total}\\n" \
      > "/tmp/meta-${req}.txt"; then
      :
    else
      printf "request=%s curl_failed\\n" "$req" > "/tmp/meta-${req}.txt"
    fi
  ) &
done
wait
for req in $(seq 1 "$TEST_CONCURRENCY"); do
  if [[ -f "/tmp/meta-${req}.txt" ]]; then
    cat "/tmp/meta-${req}.txt"
  fi
  if [[ -f "/tmp/resp-${req}.json" ]]; then
    cat "/tmp/resp-${req}.json"
  fi
  printf "\n---\n"
done'
else
  seq 1 "${QWEN_LOADTEST_TEST_CONCURRENCY}" | xargs -I{} -P "${QWEN_LOADTEST_TEST_CONCURRENCY}" \
    curl -sS --connect-timeout 10 --max-time "${QWEN_LOADTEST_TEST_REQUEST_TIMEOUT}" \
    --resolve "${QWEN_LOADTEST_HOST}:443:${gateway_target_ip}" \
    -o /tmp/qwen-loadtest-response-{}.out \
    -w 'request={} status=%{http_code} total=%{time_total}\n' \
    "https://${QWEN_LOADTEST_HOST}${QWEN_LOADTEST_TEST_PATH}"
fi

log "Current deployment status"
kubectl -n "${QWEN_LOADTEST_NAMESPACE}" get deploy,pod,svc,hpa,scaledobject

log "Current certificate status"
kubectl -n "${QWEN_LOADTEST_GATEWAY_WORKLOAD_NAMESPACE}" get certificate "${QWEN_LOADTEST_CERTIFICATE_NAME}" -o wide

log "Recent ScaledObject condition"
kubectl -n "${QWEN_LOADTEST_NAMESPACE}" describe scaledobject "${QWEN_LOADTEST_NAME}" | sed -n '1,220p'