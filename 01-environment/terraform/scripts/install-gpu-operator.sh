#!/usr/bin/env bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/common.sh"

need_cmd helm
need_cmd kubectl
need_cmd az

for required_var in \
  KUBECONFIG_FILE AZURE_SUBSCRIPTION_ID RESOURCE_GROUP CLUSTER_NAME ACR_NAME GPU_OPERATOR_CHART_DIR \
  GPU_OPERATOR_NAMESPACE GPU_DRIVER_CR_NAME GPU_DRIVER_NODE_SELECTOR_KEY GPU_DRIVER_NODE_SELECTOR_VALUE \
  GPU_DRIVER_SOURCE_REPOSITORY GPU_DRIVER_IMAGE GPU_DRIVER_VERSION GPU_DRIVER_REQUIRE_MATCHING_NODES \
  GPU_DRIVER_SYNC_ENABLED GPU_DRIVER_SYNC_USE_SUDO GPU_DRIVER_ALLOW_OS_TAG_ALIAS \
  GPU_DRIVER_VERSION_SOURCE_TAG_2204 GPU_DRIVER_VERSION_SOURCE_TAG_2404
do
  [[ -n "${!required_var:-}" ]] || fail "${required_var} is required"
done

[[ -d "${GPU_OPERATOR_CHART_DIR}" ]] || fail "GPU Operator chart not found: ${GPU_OPERATOR_CHART_DIR}"

refresh_aks_kubeconfig
wait_for_cluster_api

run_skopeo() {
  if [[ "${GPU_DRIVER_SYNC_USE_SUDO}" == "true" ]]; then
    need_cmd sudo
    sudo skopeo "$@"
  else
    skopeo "$@"
  fi
}

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

sync_driver_images_to_acr() {
  if [[ "${GPU_DRIVER_SYNC_ENABLED}" != "true" ]]; then
    log "Skipping driver image sync because GPU_DRIVER_SYNC_ENABLED=${GPU_DRIVER_SYNC_ENABLED}"
    return
  fi

  validate_driver_tag_mapping "${GPU_DRIVER_VERSION_SOURCE_TAG_2204}" "${GPU_DRIVER_VERSION}-ubuntu22.04"
  validate_driver_tag_mapping "${GPU_DRIVER_VERSION_SOURCE_TAG_2404}" "${GPU_DRIVER_VERSION}-ubuntu24.04"

  for mapping in \
    "${GPU_DRIVER_VERSION_SOURCE_TAG_2204}:${GPU_DRIVER_VERSION}-ubuntu22.04" \
    "${GPU_DRIVER_VERSION_SOURCE_TAG_2404}:${GPU_DRIVER_VERSION}-ubuntu24.04"
  do
    IFS=':' read -r source_tag target_tag <<<"${mapping}"
    log "Importing ${GPU_DRIVER_SOURCE_REPOSITORY}/${GPU_DRIVER_IMAGE}:${source_tag} -> ${acr_login_server}/${GPU_DRIVER_IMAGE}:${target_tag}"

    if run_with_retry 3 az acr import \
      --name "${ACR_NAME}" \
      --resource-group "${RESOURCE_GROUP}" \
      --source "${GPU_DRIVER_SOURCE_REPOSITORY}/${GPU_DRIVER_IMAGE}:${source_tag}" \
      --image "${GPU_DRIVER_IMAGE}:${target_tag}" \
      --force \
      --only-show-errors >/dev/null; then
      continue
    fi

    warn "az acr import failed for ${target_tag}; falling back to skopeo copy"
    need_cmd skopeo

    local acr_access_token
    acr_access_token="$(az acr login --name "${ACR_NAME}" --expose-token --query accessToken -o tsv --only-show-errors)"
    [[ -n "${acr_access_token}" ]] || fail "Failed to obtain ACR access token for ${ACR_NAME}"

    run_with_retry 3 run_skopeo copy --all \
      --dest-creds "00000000-0000-0000-0000-000000000000:${acr_access_token}" \
      "docker://${GPU_DRIVER_SOURCE_REPOSITORY}/${GPU_DRIVER_IMAGE}:${source_tag}" \
      "docker://${acr_login_server}/${GPU_DRIVER_IMAGE}:${target_tag}" \
      || fail "Failed to sync ${target_tag} into ${ACR_NAME}"
  done
}

ensure_gpu_operator_chart_deps() {
  if [[ -d "${GPU_OPERATOR_CHART_DIR}/charts/node-feature-discovery" || -f "${GPU_OPERATOR_CHART_DIR}/charts/node-feature-discovery-chart-0.18.2.tgz" ]]; then
    return
  fi

  fail "Missing vendored GPU Operator dependency under ${GPU_OPERATOR_CHART_DIR}/charts"
}

az account set --subscription "${AZURE_SUBSCRIPTION_ID}" --only-show-errors >/dev/null
acr_login_server="$(az acr show --name "${ACR_NAME}" --resource-group "${RESOURCE_GROUP}" --query loginServer -o tsv --only-show-errors)"
[[ -n "${acr_login_server}" ]] || fail "Failed to resolve login server for ACR ${ACR_NAME}"

GPU_DRIVER_TARGET_REPOSITORY="${GPU_DRIVER_TARGET_REPOSITORY:-${acr_login_server}}"

sync_driver_images_to_acr
ensure_gpu_operator_chart_deps

log "Installing GPU Operator from ${GPU_OPERATOR_CHART_DIR}"
helm upgrade --install gpu-operator \
  "${GPU_OPERATOR_CHART_DIR}" \
  --namespace "${GPU_OPERATOR_NAMESPACE}" \
  --create-namespace \
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
  --set daemonsets.tolerations[1].value=gpu-test \
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
      value: "gpu-test"
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