#!/usr/bin/env bash

GPU_OPERATOR_IMAGE_SYNC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GPU_OPERATOR_IMAGE_SYNC_CHART_DIR="${GPU_OPERATOR_IMAGE_SYNC_DIR}/../../01-environment/charts/gpu-operator"

gpu_operator_chart_app_version() {
  awk '/^appVersion:/ {print $2; exit}' "${GPU_OPERATOR_IMAGE_SYNC_CHART_DIR}/Chart.yaml"
}

gpu_operator_nfd_version() {
  awk '
    $1 == "name:" && $2 == "node-feature-discovery" { in_dependency = 1; next }
    in_dependency && $1 == "version:" { print $2; exit }
  ' "${GPU_OPERATOR_IMAGE_SYNC_CHART_DIR}/Chart.yaml"
}

gpu_operator_driver_target_repository() {
  if [[ "${GPU_DRIVER_SYNC_ENABLED:-true}" == "true" ]]; then
    image_sync_target_repo_for_source_repo "${GPU_DRIVER_SOURCE_REPOSITORY}"
  else
    printf '%s' "${GPU_DRIVER_SOURCE_REPOSITORY}"
  fi
}

log_gpu_operator_images_to_sync() {
  local gpu_operator_version="$1"
  local nfd_version="$2"

  log "GPU Operator image mirror plan:"
  log "  operator            : nvcr.io/nvidia/gpu-operator:${gpu_operator_version}"
  log "  validator/init      : nvcr.io/nvidia/cuda:13.0.1-base-ubi9"
  log "  driver manager      : nvcr.io/nvidia/cloud-native/k8s-driver-manager:v0.9.1"
  log "  toolkit             : nvcr.io/nvidia/k8s/container-toolkit:v1.18.1"
  log "  device plugin       : nvcr.io/nvidia/k8s-device-plugin:v0.18.1"
  log "  dcgm exporter       : nvcr.io/nvidia/k8s/dcgm-exporter:4.4.2-4.7.0-distroless"
  log "  dcgm                : nvcr.io/nvidia/cloud-native/dcgm:4.4.2-1-ubuntu22.04"
  log "  mig manager         : nvcr.io/nvidia/cloud-native/k8s-mig-manager:v0.13.1"
  log "  vgpu device manager : nvcr.io/nvidia/cloud-native/vgpu-device-manager:v0.4.1"
  log "  sandbox plugin      : nvcr.io/nvidia/kubevirt-gpu-device-plugin:v1.4.0"
  log "  nfd                 : registry.k8s.io/nfd/node-feature-discovery:${nfd_version}"

  if [[ "${GPU_DRIVER_SYNC_ENABLED:-true}" == "true" ]]; then
    log "  driver 22.04        : ${GPU_DRIVER_SOURCE_REPOSITORY}/${GPU_DRIVER_IMAGE}:${GPU_DRIVER_VERSION_SOURCE_TAG_2204}"
    log "  driver 24.04        : ${GPU_DRIVER_SOURCE_REPOSITORY}/${GPU_DRIVER_IMAGE}:${GPU_DRIVER_VERSION_SOURCE_TAG_2404}"
  else
    log "  driver images       : skip mirror, keep upstream repository ${GPU_DRIVER_SOURCE_REPOSITORY}"
  fi
}

sync_gpu_operator_images() {
  local gpu_operator_version
  local nfd_version

  [[ -d "${GPU_OPERATOR_IMAGE_SYNC_CHART_DIR}" ]] || fail "GPU Operator chart not found at ${GPU_OPERATOR_IMAGE_SYNC_CHART_DIR}"

  GPU_DRIVER_SOURCE_REPOSITORY="${GPU_DRIVER_SOURCE_REPOSITORY:-docker.io/yingeli}"
  GPU_DRIVER_IMAGE="${GPU_DRIVER_IMAGE:-driver}"
  GPU_DRIVER_VERSION="${GPU_DRIVER_VERSION:-580.105.08}"
  GPU_DRIVER_VERSION_SOURCE_TAG_2204="${GPU_DRIVER_VERSION_SOURCE_TAG_2204:-${GPU_DRIVER_VERSION}-ubuntu22.04}"
  GPU_DRIVER_VERSION_SOURCE_TAG_2404="${GPU_DRIVER_VERSION_SOURCE_TAG_2404:-${GPU_DRIVER_VERSION}-ubuntu24.04}"

  gpu_operator_version="$(gpu_operator_chart_app_version)"
  nfd_version="$(gpu_operator_nfd_version)"
  [[ -n "${gpu_operator_version}" ]] || fail "Unable to determine GPU Operator appVersion"
  [[ -n "${nfd_version}" ]] || fail "Unable to determine Node Feature Discovery chart version"

  GPU_OPERATOR_MIRROR_NVIDIA_REPOSITORY="$(image_sync_target_repo_for_source_repo "nvcr.io/nvidia")"
  GPU_OPERATOR_MIRROR_NVIDIA_CLOUD_NATIVE_REPOSITORY="$(image_sync_target_repo_for_source_repo "nvcr.io/nvidia/cloud-native")"
  GPU_OPERATOR_MIRROR_NVIDIA_K8S_REPOSITORY="$(image_sync_target_repo_for_source_repo "nvcr.io/nvidia/k8s")"
  GPU_OPERATOR_MIRROR_NFD_REPOSITORY="$(image_sync_target_repo_for_source_repo "registry.k8s.io/nfd/node-feature-discovery")"
  GPU_DRIVER_TARGET_REPOSITORY="$(gpu_operator_driver_target_repository)"

  export GPU_DRIVER_TARGET_REPOSITORY
  export GPU_OPERATOR_MIRROR_NVIDIA_REPOSITORY
  export GPU_OPERATOR_MIRROR_NVIDIA_CLOUD_NATIVE_REPOSITORY
  export GPU_OPERATOR_MIRROR_NVIDIA_K8S_REPOSITORY
  export GPU_OPERATOR_MIRROR_NFD_REPOSITORY

  image_sync_write_env_if_available GPU_DRIVER_TARGET_REPOSITORY "${GPU_DRIVER_TARGET_REPOSITORY}"
  image_sync_write_env_if_available GPU_OPERATOR_MIRROR_NVIDIA_REPOSITORY "${GPU_OPERATOR_MIRROR_NVIDIA_REPOSITORY}"
  image_sync_write_env_if_available GPU_OPERATOR_MIRROR_NVIDIA_CLOUD_NATIVE_REPOSITORY "${GPU_OPERATOR_MIRROR_NVIDIA_CLOUD_NATIVE_REPOSITORY}"
  image_sync_write_env_if_available GPU_OPERATOR_MIRROR_NVIDIA_K8S_REPOSITORY "${GPU_OPERATOR_MIRROR_NVIDIA_K8S_REPOSITORY}"
  image_sync_write_env_if_available GPU_OPERATOR_MIRROR_NFD_REPOSITORY "${GPU_OPERATOR_MIRROR_NFD_REPOSITORY}"

  log_gpu_operator_images_to_sync "${gpu_operator_version}" "${nfd_version}"

  image_sync_import_ref "nvcr.io/nvidia/gpu-operator:${gpu_operator_version}" "nvcr.io/nvidia/gpu-operator:${gpu_operator_version}"
  image_sync_import_ref "nvcr.io/nvidia/cuda:13.0.1-base-ubi9" "nvcr.io/nvidia/cuda:13.0.1-base-ubi9"
  image_sync_import_ref "nvcr.io/nvidia/cloud-native/k8s-driver-manager:v0.9.1" "nvcr.io/nvidia/cloud-native/k8s-driver-manager:v0.9.1"
  image_sync_import_ref "nvcr.io/nvidia/k8s/container-toolkit:v1.18.1" "nvcr.io/nvidia/k8s/container-toolkit:v1.18.1"
  image_sync_import_ref "nvcr.io/nvidia/k8s/dcgm-exporter:4.4.2-4.7.0-distroless" "nvcr.io/nvidia/k8s/dcgm-exporter:4.4.2-4.7.0-distroless"
  image_sync_import_ref "nvcr.io/nvidia/k8s-device-plugin:v0.18.1" "nvcr.io/nvidia/k8s-device-plugin:v0.18.1"
  image_sync_import_ref "nvcr.io/nvidia/cloud-native/dcgm:4.4.2-1-ubuntu22.04" "nvcr.io/nvidia/cloud-native/dcgm:4.4.2-1-ubuntu22.04"
  image_sync_import_ref "nvcr.io/nvidia/cloud-native/k8s-mig-manager:v0.13.1" "nvcr.io/nvidia/cloud-native/k8s-mig-manager:v0.13.1"
  image_sync_import_ref "nvcr.io/nvidia/cloud-native/vgpu-device-manager:v0.4.1" "nvcr.io/nvidia/cloud-native/vgpu-device-manager:v0.4.1"
  image_sync_import_ref "nvcr.io/nvidia/kubevirt-gpu-device-plugin:v1.4.0" "nvcr.io/nvidia/kubevirt-gpu-device-plugin:v1.4.0"
  image_sync_import_ref "registry.k8s.io/nfd/node-feature-discovery:${nfd_version}" "registry.k8s.io/nfd/node-feature-discovery:${nfd_version}"

  if [[ "${GPU_DRIVER_SYNC_ENABLED:-true}" == "true" ]]; then
    image_sync_import_ref \
      "${GPU_DRIVER_SOURCE_REPOSITORY}/${GPU_DRIVER_IMAGE}:${GPU_DRIVER_VERSION_SOURCE_TAG_2204}" \
      "${GPU_DRIVER_SOURCE_REPOSITORY}/${GPU_DRIVER_IMAGE}:${GPU_DRIVER_VERSION}-ubuntu22.04"
    image_sync_import_ref \
      "${GPU_DRIVER_SOURCE_REPOSITORY}/${GPU_DRIVER_IMAGE}:${GPU_DRIVER_VERSION_SOURCE_TAG_2404}" \
      "${GPU_DRIVER_SOURCE_REPOSITORY}/${GPU_DRIVER_IMAGE}:${GPU_DRIVER_VERSION}-ubuntu24.04"
  fi
}

write_gpu_operator_mirror_values_file() {
  local target_file="$1"
  local gpu_node_class="${GPU_NODE_CLASS:-${GPU_NODE_WORKLOAD_LABEL:-gpu}}"
  local gpu_node_scheduling_key="${GPU_NODE_SCHEDULING_KEY:-scheduling.azure-gpu-demo/dedicated}"

  [[ -n "${GPU_DRIVER_TARGET_REPOSITORY:-}" ]] || fail "GPU_DRIVER_TARGET_REPOSITORY is not initialized"
  [[ -n "${GPU_OPERATOR_MIRROR_NVIDIA_REPOSITORY:-}" ]] || fail "GPU operator mirror repositories are not initialized"

  cat >"${target_file}" <<EOF
validator:
  repository: ${GPU_OPERATOR_MIRROR_NVIDIA_REPOSITORY}
operator:
  repository: ${GPU_OPERATOR_MIRROR_NVIDIA_REPOSITORY}
  initContainer:
    repository: ${GPU_OPERATOR_MIRROR_NVIDIA_REPOSITORY}
driver:
  repository: ${GPU_DRIVER_TARGET_REPOSITORY}
  manager:
    repository: ${GPU_OPERATOR_MIRROR_NVIDIA_CLOUD_NATIVE_REPOSITORY}
toolkit:
  repository: ${GPU_OPERATOR_MIRROR_NVIDIA_K8S_REPOSITORY}
devicePlugin:
  repository: ${GPU_OPERATOR_MIRROR_NVIDIA_REPOSITORY}
dcgm:
  repository: ${GPU_OPERATOR_MIRROR_NVIDIA_CLOUD_NATIVE_REPOSITORY}
dcgmExporter:
  repository: ${GPU_OPERATOR_MIRROR_NVIDIA_K8S_REPOSITORY}
gfd:
  repository: ${GPU_OPERATOR_MIRROR_NVIDIA_REPOSITORY}
migManager:
  repository: ${GPU_OPERATOR_MIRROR_NVIDIA_CLOUD_NATIVE_REPOSITORY}
nodeStatusExporter:
  repository: ${GPU_OPERATOR_MIRROR_NVIDIA_REPOSITORY}
gds:
  repository: ${GPU_OPERATOR_MIRROR_NVIDIA_CLOUD_NATIVE_REPOSITORY}
gdrcopy:
  repository: ${GPU_OPERATOR_MIRROR_NVIDIA_CLOUD_NATIVE_REPOSITORY}
vgpuDeviceManager:
  repository: ${GPU_OPERATOR_MIRROR_NVIDIA_CLOUD_NATIVE_REPOSITORY}
vfioManager:
  repository: ${GPU_OPERATOR_MIRROR_NVIDIA_REPOSITORY}
  driverManager:
    repository: ${GPU_OPERATOR_MIRROR_NVIDIA_CLOUD_NATIVE_REPOSITORY}
sandboxDevicePlugin:
  repository: ${GPU_OPERATOR_MIRROR_NVIDIA_REPOSITORY}
kataManager:
  repository: ${GPU_OPERATOR_MIRROR_NVIDIA_CLOUD_NATIVE_REPOSITORY}
ccManager:
  repository: ${GPU_OPERATOR_MIRROR_NVIDIA_CLOUD_NATIVE_REPOSITORY}
node-feature-discovery:
  image:
    repository: ${GPU_OPERATOR_MIRROR_NFD_REPOSITORY}
  worker:
    tolerations:
    - key: "node-role.kubernetes.io/master"
      operator: "Equal"
      value: ""
      effect: "NoSchedule"
    - key: "node-role.kubernetes.io/control-plane"
      operator: "Equal"
      value: ""
      effect: "NoSchedule"
    - key: nvidia.com/gpu
      operator: Exists
      effect: NoSchedule
    - key: "${gpu_node_scheduling_key}"
      operator: "Equal"
      value: "${gpu_node_class}"
      effect: "NoSchedule"
    - key: "kubernetes.azure.com/scalesetpriority"
      operator: "Equal"
      value: "spot"
      effect: "NoSchedule"
EOF
}
