#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../../common.sh"

load_env
need_cmd kubectl
need_cmd python3

require_env AZ_SUBSCRIPTION_ID RESOURCE_GROUP CLUSTER_NAME

ensure_aks_kubeconfig

QWEN_SCALE_TEST_RUN_ID="${QWEN_SCALE_TEST_RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)}"
QWEN_SCALE_TEST_OUTPUT_ROOT="${QWEN_SCALE_TEST_OUTPUT_ROOT:-${ROOT_DIR}/test-results/qwen-scale}"
QWEN_SCALE_TEST_OUTPUT_DIR="${QWEN_SCALE_TEST_OUTPUT_DIR:-${QWEN_SCALE_TEST_OUTPUT_ROOT}/${QWEN_SCALE_TEST_RUN_ID}}"
QWEN_SCALE_TEST_MONITOR_INTERVAL_SECONDS="${QWEN_SCALE_TEST_MONITOR_INTERVAL_SECONDS:-15}"
QWEN_SCALE_TEST_DEPLOY_FIRST="${QWEN_SCALE_TEST_DEPLOY_FIRST:-false}"
QWEN_SCALE_TEST_PHASES="${QWEN_SCALE_TEST_PHASES:-warmup:300:1:6:2.5,ramp1:600:2:6:2.5,ramp2:600:4:6:2.5,ramp3:600:6:6:2.5,ramp4:900:9:6:2.5}"
QWEN_SCALE_TEST_EXPECT_GPU_NODE_COUNT="${QWEN_SCALE_TEST_EXPECT_GPU_NODE_COUNT:-1}"
gpu_node_class="${GPU_NODE_CLASS:-${GPU_NODE_WORKLOAD_LABEL:-gpu}}"
gpu_node_scheduling_key="${GPU_NODE_SCHEDULING_KEY:-scheduling.azure-gpu-demo/dedicated}"
gpu_node_selector="${QWEN_SCALE_TEST_GPU_NODE_SELECTOR:-${gpu_node_scheduling_key}=${gpu_node_class}}"
gpu_driver_pod_prefixes="${QWEN_SCALE_TEST_DRIVER_POD_PREFIXES:-${GPU_DRIVER_POD_PREFIXES:-nvidia-vgpu-driver,nvidia-driver-daemonset}}"

if [[ "${QWEN_SCALE_TEST_EXPECT_GPU_NODE_COUNT}" =~ ^[0-9]+$ ]]; then
  current_gpu_node_count="$(kubectl get nodes -l "${gpu_node_selector}" --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  [[ "${current_gpu_node_count}" == "${QWEN_SCALE_TEST_EXPECT_GPU_NODE_COUNT}" ]] || fail "Expected ${QWEN_SCALE_TEST_EXPECT_GPU_NODE_COUNT} GPU nodes matching ${gpu_node_selector} before test start, found ${current_gpu_node_count}. Clean up stale nodeclaims first."
fi

mkdir -p "${QWEN_SCALE_TEST_OUTPUT_DIR}"

monitor_log="${QWEN_SCALE_TEST_OUTPUT_DIR}/monitor.log"
phase_plan_file="${QWEN_SCALE_TEST_OUTPUT_DIR}/phase-plan.tsv"

cat >"${phase_plan_file}" <<EOF
phase\tduration_seconds\tconcurrency\tsteps\tcfg
EOF

python3 "${SCRIPT_DIR}/scripts/monitor-scale.py" \
  --output-dir "${QWEN_SCALE_TEST_OUTPUT_DIR}" \
  --poll-interval "${QWEN_SCALE_TEST_MONITOR_INTERVAL_SECONDS}" \
  --gpu-node-selector "${gpu_node_selector}" \
  --driver-pod-prefixes "${gpu_driver_pod_prefixes}" \
  >>"${monitor_log}" 2>&1 &
monitor_pid=$!

cleanup() {
  if kill -0 "${monitor_pid}" >/dev/null 2>&1; then
    kill -TERM "${monitor_pid}" >/dev/null 2>&1 || true
    wait "${monitor_pid}" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

if [[ "${QWEN_SCALE_TEST_DEPLOY_FIRST}" == "true" ]]; then
  log "Deploying qwen workload after monitor startup"
  "${SCRIPT_DIR}/41-deploy.sh" | tee "${QWEN_SCALE_TEST_OUTPUT_DIR}/00-deploy.log"
fi

log "Running baseline smoke test before ramp phases"
"${SCRIPT_DIR}/42-smoke-test.sh" | tee "${QWEN_SCALE_TEST_OUTPUT_DIR}/00-smoke.log"

IFS=',' read -r -a phases <<<"${QWEN_SCALE_TEST_PHASES}"

for phase in "${phases[@]}"; do
  IFS=':' read -r phase_name phase_duration phase_concurrency phase_steps phase_cfg <<<"${phase}"
  printf '%s\t%s\t%s\t%s\t%s\n' "${phase_name}" "${phase_duration}" "${phase_concurrency}" "${phase_steps}" "${phase_cfg}" >>"${phase_plan_file}"

  log "Starting phase ${phase_name}: duration=${phase_duration}s concurrency=${phase_concurrency} steps=${phase_steps} cfg=${phase_cfg}"
  QWEN_LOADTEST_STRESS_DURATION_SECONDS="${phase_duration}" \
  QWEN_LOADTEST_STRESS_CONCURRENCY="${phase_concurrency}" \
  QWEN_LOADTEST_STRESS_STEPS="${phase_steps}" \
  QWEN_LOADTEST_STRESS_CFG="${phase_cfg}" \
  "${SCRIPT_DIR}/44-stress-test.sh" | tee "${QWEN_SCALE_TEST_OUTPUT_DIR}/${phase_name}-stress.log"

  kubectl -n "${QWEN_LOADTEST_NAMESPACE:-qwen-loadtest}" get deploy,pod,svc,hpa,scaledobject -o wide >"${QWEN_SCALE_TEST_OUTPUT_DIR}/${phase_name}-resources.txt" || true
  kubectl -n "${QWEN_LOADTEST_NAMESPACE:-qwen-loadtest}" describe scaledobject "${QWEN_LOADTEST_ELASTIC_SCALEDOBJECT_NAME:-qwen-loadtest-target-elastic}" >"${QWEN_SCALE_TEST_OUTPUT_DIR}/${phase_name}-elastic-scaledobject.txt" || true
  kubectl -n "${QWEN_LOADTEST_NAMESPACE:-qwen-loadtest}" describe scaledobject "${QWEN_LOADTEST_SEED_SCALEDOBJECT_NAME:-qwen-loadtest-target-seed}" >"${QWEN_SCALE_TEST_OUTPUT_DIR}/${phase_name}-baseline-scaledobject.txt" || true
done

cleanup
trap - EXIT

log "Ramp test completed. Results stored in ${QWEN_SCALE_TEST_OUTPUT_DIR}"