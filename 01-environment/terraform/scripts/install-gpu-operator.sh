#!/usr/bin/env bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/common.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../../scripts/prepared-image-env.sh"

if [[ -n "${SHARED_ENV_FILE:-}" && -f "${SHARED_ENV_FILE}" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "${SHARED_ENV_FILE}"
  set +a
fi

need_cmd helm
need_cmd kubectl

for required_var in \
  KUBECONFIG_FILE AZURE_SUBSCRIPTION_ID RESOURCE_GROUP CLUSTER_NAME GPU_OPERATOR_CHART_DIR \
  GPU_OPERATOR_NAMESPACE GPU_DRIVER_CR_NAME GPU_DRIVER_NODE_SELECTOR_KEY GPU_DRIVER_NODE_SELECTOR_VALUE \
  GPU_DRIVER_IMAGE GPU_DRIVER_VERSION GPU_DRIVER_REQUIRE_MATCHING_NODES GPU_NODE_WORKLOAD_LABEL \
  GPU_DRIVER_TARGET_REPOSITORY GPU_OPERATOR_MIRROR_NVIDIA_REPOSITORY \
  GPU_OPERATOR_MIRROR_NVIDIA_CLOUD_NATIVE_REPOSITORY GPU_OPERATOR_MIRROR_NVIDIA_K8S_REPOSITORY \
  GPU_OPERATOR_MIRROR_NFD_REPOSITORY
do
  [[ -n "${!required_var:-}" ]] || fail "${required_var} is required"
done

[[ -d "${GPU_OPERATOR_CHART_DIR}" ]] || fail "GPU Operator chart not found: ${GPU_OPERATOR_CHART_DIR}"

refresh_aks_kubeconfig
wait_for_cluster_api

run_with_retry() {
  local max_attempts="$1"
  shift

  local attempt
  for attempt in $(seq 1 "${max_attempts}"); do
    if "$@"; then
      return 0
    fi

    if [[ "${attempt}" -lt "${max_attempts}" ]]; then
      warn "Command failed, retrying ${attempt}/${max_attempts}: $*"
      sleep 10
    fi
  done

  return 1
}

ensure_gpu_operator_chart_deps() {
  if [[ -d "${GPU_OPERATOR_CHART_DIR}/charts/node-feature-discovery" || -f "${GPU_OPERATOR_CHART_DIR}/charts/node-feature-discovery-chart-0.18.2.tgz" ]]; then
    return
  fi

  fail "Missing vendored GPU Operator dependency under ${GPU_OPERATOR_CHART_DIR}/charts"
}

ensure_gpu_operator_chart_deps

tmp_values_file="$(mktemp)"
cleanup() {
  rm -f "${tmp_values_file}"
}
trap cleanup EXIT
write_gpu_operator_mirror_values_file "${tmp_values_file}"

log "Installing GPU Operator from ${GPU_OPERATOR_CHART_DIR}"
log "GPU Operator mirrored repositories:"
log "  operator repo      : ${GPU_OPERATOR_MIRROR_NVIDIA_REPOSITORY}"
log "  cloud-native repo  : ${GPU_OPERATOR_MIRROR_NVIDIA_CLOUD_NATIVE_REPOSITORY}"
log "  k8s repo           : ${GPU_OPERATOR_MIRROR_NVIDIA_K8S_REPOSITORY}"
log "  nfd repo           : ${GPU_OPERATOR_MIRROR_NFD_REPOSITORY}"
log "  driver repo        : ${GPU_DRIVER_TARGET_REPOSITORY}"
helm upgrade --install gpu-operator \
  "${GPU_OPERATOR_CHART_DIR}" \
  --namespace "${GPU_OPERATOR_NAMESPACE}" \
  --create-namespace \
  -f "${tmp_values_file}" \
  --set driver.enabled=false \
  --set driver.nvidiaDriverCRD.enabled=true \
  --set driver.nvidiaDriverCRD.deployDefaultCR=false \
  --set toolkit.enabled=true \
  --set devicePlugin.enabled=true \
  --set dcgmExporter.enabled=true \
  --set dcgmExporter.serviceMonitor.enabled=true \
  --set daemonsets.tolerations[0].key=nvidia.com/gpu \
  --set daemonsets.tolerations[0].operator=Exists \
  --set daemonsets.tolerations[0].effect=NoSchedule \
  --set daemonsets.tolerations[1].key=workload \
  --set daemonsets.tolerations[1].operator=Equal \
  --set daemonsets.tolerations[1].value=${GPU_NODE_WORKLOAD_LABEL} \
  --set daemonsets.tolerations[1].effect=NoSchedule \
  --set daemonsets.tolerations[2].key=kubernetes.azure.com/scalesetpriority \
  --set daemonsets.tolerations[2].operator=Equal \
  --set daemonsets.tolerations[2].value=spot \
  --set daemonsets.tolerations[2].effect=NoSchedule \
  --wait \
  --timeout 10m

kubectl -n "${GPU_OPERATOR_NAMESPACE}" rollout status deploy/gpu-operator --timeout=5m 2>/dev/null || true

expected_selector="${GPU_DRIVER_NODE_SELECTOR_KEY}=${GPU_DRIVER_NODE_SELECTOR_VALUE}"
matching_gpu_nodes="$(kubectl get nodes -l "${expected_selector}" -o name 2>/dev/null || true)"
if [[ -z "${matching_gpu_nodes}" && "${GPU_DRIVER_REQUIRE_MATCHING_NODES}" == "true" ]]; then
  fail "No GPU nodes match ${expected_selector}; adjust the selector or provision a matching node first"
fi

if [[ -z "${matching_gpu_nodes}" ]]; then
  warn "No GPU nodes currently match ${expected_selector}; applying NVIDIADriver for future Karpenter nodes"
fi

existing_selector="$(kubectl get nvidiadriver "${GPU_DRIVER_CR_NAME}" -o go-template='{{range $k, $v := .spec.nodeSelector}}{{printf "%s=%s" $k $v}}{{end}}' 2>/dev/null || true)"
if [[ -n "${existing_selector}" && "${existing_selector}" != "${expected_selector}" ]]; then
  kubectl delete nvidiadriver "${GPU_DRIVER_CR_NAME}" --ignore-not-found --wait=true >/dev/null 2>&1 || true
fi

cat <<EOF | kubectl apply -f -
apiVersion: nvidia.com/v1alpha1
kind: NVIDIADriver
metadata:
  name: ${GPU_DRIVER_CR_NAME}
spec:
  tolerations:
    - key: "workload"
      operator: "Equal"
      value: "${GPU_NODE_WORKLOAD_LABEL}"
      effect: "NoSchedule"
    - key: "kubernetes.azure.com/scalesetpriority"
      operator: "Equal"
      value: "spot"
      effect: "NoSchedule"
    - key: "nvidia.com/gpu"
      operator: "Exists"
      effect: "NoSchedule"
  nodeSelector:
    ${GPU_DRIVER_NODE_SELECTOR_KEY}: "${GPU_DRIVER_NODE_SELECTOR_VALUE}"
  driverType: vgpu
  image: ${GPU_DRIVER_IMAGE}
  repository: "${GPU_DRIVER_TARGET_REPOSITORY}"
  version: "${GPU_DRIVER_VERSION}"
EOF

log "GPU Operator deployment completed"