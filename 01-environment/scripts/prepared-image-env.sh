#!/usr/bin/env bash

write_gpu_operator_mirror_values_file() {
  local target_file="$1"
  local gpu_node_class="${GPU_NODE_CLASS:-${GPU_NODE_WORKLOAD_LABEL:-gpu}}"
  local gpu_node_scheduling_key="${GPU_NODE_SCHEDULING_KEY:-scheduling.azure-gpu-demo/dedicated}"

  [[ -n "${GPU_DRIVER_TARGET_REPOSITORY:-}" ]] || fail "GPU_DRIVER_TARGET_REPOSITORY is required"
  [[ -n "${GPU_OPERATOR_MIRROR_NVIDIA_REPOSITORY:-}" ]] || fail "GPU_OPERATOR_MIRROR_NVIDIA_REPOSITORY is required"
  [[ -n "${GPU_OPERATOR_MIRROR_NVIDIA_CLOUD_NATIVE_REPOSITORY:-}" ]] || fail "GPU_OPERATOR_MIRROR_NVIDIA_CLOUD_NATIVE_REPOSITORY is required"
  [[ -n "${GPU_OPERATOR_MIRROR_NVIDIA_K8S_REPOSITORY:-}" ]] || fail "GPU_OPERATOR_MIRROR_NVIDIA_K8S_REPOSITORY is required"
  [[ -n "${GPU_OPERATOR_MIRROR_NFD_REPOSITORY:-}" ]] || fail "GPU_OPERATOR_MIRROR_NFD_REPOSITORY is required"

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