#!/usr/bin/env bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/common.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../../scripts/image-sync-lib.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../../scripts/gpu-operator-image-sync.sh"

need_cmd helm
need_cmd kubectl
need_cmd az

for required_var in \
  KUBECONFIG_FILE AZURE_SUBSCRIPTION_ID RESOURCE_GROUP CLUSTER_NAME ACR_NAME GPU_OPERATOR_CHART_DIR \
  GPU_OPERATOR_NAMESPACE GPU_DRIVER_CR_NAME GPU_DRIVER_NODE_SELECTOR_KEY GPU_DRIVER_NODE_SELECTOR_VALUE \
  GPU_DRIVER_SOURCE_REPOSITORY GPU_DRIVER_IMAGE GPU_DRIVER_VERSION GPU_DRIVER_REQUIRE_MATCHING_NODES \
  GPU_DRIVER_SYNC_ENABLED GPU_DRIVER_SYNC_USE_SUDO GPU_DRIVER_ALLOW_OS_TAG_ALIAS \
  GPU_DRIVER_VERSION_SOURCE_TAG_2204 GPU_DRIVER_VERSION_SOURCE_TAG_2404 GPU_NODE_WORKLOAD_LABEL
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

validate_driver_tag_mapping() {
  local source_tag="$1"
  local target_tag="$2"
  local source_os_tag="${source_tag##*-}"
  local target_os_tag="${target_tag##*-}"

  if [[ "${source_os_tag}" != "${target_os_tag}" && "${GPU_DRIVER_ALLOW_OS_TAG_ALIAS}" != "true" ]]; then
    fail "Refusing to alias driver image ${source_tag} to ${target_tag}. Set GPU_DRIVER_ALLOW_OS_TAG_ALIAS=true to override."
  fi
}

ensure_gpu_operator_chart_deps() {
  if [[ -d "${GPU_OPERATOR_CHART_DIR}/charts/node-feature-discovery" || -f "${GPU_OPERATOR_CHART_DIR}/charts/node-feature-discovery-chart-0.18.2.tgz" ]]; then
    return
  fi

  fail "Missing vendored GPU Operator dependency under ${GPU_OPERATOR_CHART_DIR}/charts"
}

az account set --subscription "${AZURE_SUBSCRIPTION_ID}" --only-show-errors >/dev/null
if [[ "${GPU_DRIVER_SYNC_ENABLED}" == "true" ]]; then
  validate_driver_tag_mapping "${GPU_DRIVER_VERSION_SOURCE_TAG_2204}" "${GPU_DRIVER_VERSION}-ubuntu22.04"
  validate_driver_tag_mapping "${GPU_DRIVER_VERSION_SOURCE_TAG_2404}" "${GPU_DRIVER_VERSION}-ubuntu24.04"
fi

sync_gpu_operator_images
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