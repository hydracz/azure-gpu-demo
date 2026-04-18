#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../../common.sh"

load_env
ensure_tooling

: "${DRAGONFLY_ENABLED:=true}"
: "${DRAGONFLY_NAMESPACE:=dragonfly-system}"
: "${DRAGONFLY_RELEASE_NAME:=dragonfly}"
: "${DRAGONFLY_CHART_VERSION:=1.6.13}"
: "${SYSTEM_POOL_NAME:=sysd4}"
: "${SYSTEM_NODE_COUNT:=3}"
: "${DRAGONFLY_CONTAINERD_CONFIG_DAEMONSET_NAME:=dragonfly-containerd-configurer}"
: "${DRAGONFLY_CONTAINERD_CONFIG_CONFIGMAP_NAME:=dragonfly-containerd-config}"
: "${DRAGONFLY_MANAGER_REPLICAS:=1}"
: "${DRAGONFLY_SCHEDULER_REPLICAS:=1}"
: "${DRAGONFLY_SEED_CLIENT_REPLICAS:=1}"
: "${DRAGONFLY_MANAGER_IMAGE_REPOSITORY:=dragonflyoss/manager}"
: "${DRAGONFLY_MANAGER_IMAGE_TAG:=v2.4.1}"
: "${DRAGONFLY_SCHEDULER_IMAGE_REPOSITORY:=dragonflyoss/scheduler}"
: "${DRAGONFLY_SCHEDULER_IMAGE_TAG:=v2.4.1}"
: "${DRAGONFLY_CLIENT_IMAGE_REPOSITORY:=dragonflyoss/client}"
: "${DRAGONFLY_CLIENT_IMAGE_TAG:=v1.2.9}"
: "${DRAGONFLY_BUSYBOX_IMAGE_REPOSITORY:=busybox}"
: "${DRAGONFLY_BUSYBOX_IMAGE_TAG:=latest}"
: "${DRAGONFLY_MYSQL_IMAGE_REPOSITORY:=bitnamilegacy/mysql}"
: "${DRAGONFLY_MYSQL_IMAGE_TAG:=8.0.36-debian-12-r10}"
: "${DRAGONFLY_REDIS_IMAGE_REPOSITORY:=bitnamilegacy/redis}"
: "${DRAGONFLY_REDIS_IMAGE_TAG:=7.2.5-debian-12-r0}"
: "${DRAGONFLY_CONTAINERD_REGISTRIES_CSV:=docker.io,ghcr.io,nvcr.io}"
: "${GPU_NODE_CLASS:=$(resolve_gpu_node_class)}"

[[ "${DRAGONFLY_ENABLED:-true}" == "true" ]] || fail "DRAGONFLY_ENABLED=false; set it to true before deploying Dragonfly"

DRAGONFLY_CHART_FILE="${ROOT_DIR}/01-environment/charts/dragonfly-${DRAGONFLY_CHART_VERSION}.tgz"
[[ -f "${DRAGONFLY_CHART_FILE}" ]] || fail "Dragonfly chart package not found at ${DRAGONFLY_CHART_FILE}"

require_env \
  AZ_SUBSCRIPTION_ID RESOURCE_GROUP CLUSTER_NAME ACR_LOGIN_SERVER \
  DRAGONFLY_NAMESPACE DRAGONFLY_RELEASE_NAME SYSTEM_POOL_NAME SYSTEM_NODE_COUNT \
  DRAGONFLY_CONTAINERD_CONFIG_DAEMONSET_NAME DRAGONFLY_CONTAINERD_CONFIG_CONFIGMAP_NAME \
  GPU_NODE_CLASS \
  DRAGONFLY_MANAGER_REPLICAS DRAGONFLY_SCHEDULER_REPLICAS DRAGONFLY_SEED_CLIENT_REPLICAS \
  DRAGONFLY_MANAGER_IMAGE_REPOSITORY DRAGONFLY_MANAGER_IMAGE_TAG \
  DRAGONFLY_SCHEDULER_IMAGE_REPOSITORY DRAGONFLY_SCHEDULER_IMAGE_TAG \
  DRAGONFLY_CLIENT_IMAGE_REPOSITORY DRAGONFLY_CLIENT_IMAGE_TAG \
  DRAGONFLY_BUSYBOX_IMAGE_REPOSITORY DRAGONFLY_BUSYBOX_IMAGE_TAG \
  DRAGONFLY_MYSQL_IMAGE_REPOSITORY DRAGONFLY_MYSQL_IMAGE_TAG \
  DRAGONFLY_REDIS_IMAGE_REPOSITORY DRAGONFLY_REDIS_IMAGE_TAG

[[ "${DRAGONFLY_MANAGER_REPLICAS}" =~ ^[0-9]+$ ]] || fail "DRAGONFLY_MANAGER_REPLICAS must be an integer"
[[ "${DRAGONFLY_SCHEDULER_REPLICAS}" =~ ^[0-9]+$ ]] || fail "DRAGONFLY_SCHEDULER_REPLICAS must be an integer"
[[ "${DRAGONFLY_SEED_CLIENT_REPLICAS}" =~ ^[0-9]+$ ]] || fail "DRAGONFLY_SEED_CLIENT_REPLICAS must be an integer"

ensure_aks_kubeconfig
kubectl create namespace "${DRAGONFLY_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
gpu_node_scheduling_key="${GPU_NODE_SCHEDULING_KEY:-scheduling.azure-gpu-demo/dedicated}"

system_node_selector_yaml="$(cat <<EOF
    kubernetes.azure.com/mode: system
    agentpool: ${SYSTEM_POOL_NAME}
EOF
)"

workload_node_selector_yaml="$(cat <<EOF
    ${gpu_node_scheduling_key}: ${GPU_NODE_CLASS}
EOF
)"

seed_workload_node_selector_yaml="$(cat <<EOF
    ${gpu_node_scheduling_key}: ${GPU_NODE_CLASS}
    karpenter.sh/capacity-type: on-demand
EOF
)"

workload_tolerations_yaml="$(cat <<EOF
    - key: ${gpu_node_scheduling_key}
      operator: Equal
      value: ${GPU_NODE_CLASS}
      effect: NoSchedule
    - key: kubernetes.azure.com/scalesetpriority
      operator: Equal
      value: spot
      effect: NoSchedule
    - key: nvidia.com/gpu
      operator: Exists
      effect: NoSchedule
EOF
)"

seed_client_affinity_yaml="$(cat <<'EOF'
    podAntiAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        - labelSelector:
            matchExpressions:
              - key: component
                operator: In
                values:
                  - seed-client
          topologyKey: kubernetes.io/hostname
EOF
)"

containerd_registry_yaml="$(python3 - <<'PY' "${ACR_LOGIN_SERVER}" "${DRAGONFLY_CONTAINERD_REGISTRIES_CSV:-docker.io,ghcr.io,nvcr.io}"
import sys

acr = sys.argv[1].strip()
extra = [item.strip() for item in sys.argv[2].split(',') if item.strip()]
registries = [acr] + extra
seen = set()

for host in registries:
    if host in seen:
        continue
    seen.add(host)
    server = "https://index.docker.io" if host == "docker.io" else f"https://{host}"
    print(f"            - hostNamespace: {host}")
    print(f"              serverAddr: {server}")
    print('              capabilities: ["pull", "resolve"]')
PY
)"

containerd_registry_hosts_files="$(python3 - <<'PY' "${ACR_LOGIN_SERVER}" "${DRAGONFLY_CONTAINERD_REGISTRIES_CSV:-docker.io,ghcr.io,nvcr.io}"
import sys

acr = sys.argv[1].strip()
extra = [item.strip() for item in sys.argv[2].split(',') if item.strip()]
registries = [acr] + extra
seen = set()

for host in registries:
  if host in seen:
    continue

  seen.add(host)
  server = "https://index.docker.io" if host == "docker.io" else f"https://{host}"
  print(f"FILE:{host}.hosts.toml")

  lines = [
    f'server = "{server}"',
    '',
    '[host."http://127.0.0.1:4001"]',
    '  capabilities = ["pull", "resolve"]',
    '  [host."http://127.0.0.1:4001".header]',
    f'    X-Dragonfly-Registry = "{server}"',
    '',
    f'[host."{server}"]',
    '  capabilities = ["pull", "resolve"]',
  ]

  for line in lines:
    print(line)
PY
)"

containerd_registry_dropin_toml="$(cat <<'EOF'
version = 3

[plugins."io.containerd.cri.v1.images"]
  use_local_image_pull = true

  [plugins."io.containerd.cri.v1.images".registry]
    config_path = "/etc/containerd/certs.d"
EOF
)"

containerd_configurer_script="$(cat <<'EOF'
#!/bin/sh
set -eu

changed=0

mkdir -p /host/etc/containerd/conf.d
mkdir -p /host/etc/containerd/certs.d

if ! cmp -s /config/10-dragonfly-registry.toml /host/etc/containerd/conf.d/10-dragonfly-registry.toml 2>/dev/null; then
  cp /config/10-dragonfly-registry.toml /host/etc/containerd/conf.d/10-dragonfly-registry.toml
  changed=1
fi

for src in /config/*.hosts.toml; do
  [ -e "$src" ] || continue
  registry="$(basename "$src" .hosts.toml)"
  dest_dir="/host/etc/containerd/certs.d/${registry}"
  dest_file="${dest_dir}/hosts.toml"
  mkdir -p "${dest_dir}"
  if ! cmp -s "$src" "$dest_file" 2>/dev/null; then
    cp "$src" "$dest_file"
    changed=1
  fi
done

if [ "$changed" -eq 1 ]; then
  nsenter -t 1 -m -- systemctl restart containerd.service
fi
EOF
)"

tmp_values_file="$(mktemp)"
tmp_containerd_config_dir="$(mktemp -d)"
cleanup() {
  rm -f "${tmp_values_file}"
  rm -rf "${tmp_containerd_config_dir}"
}
trap cleanup EXIT

cat >"${tmp_values_file}" <<EOF
global:
  imageRegistry: ${ACR_LOGIN_SERVER}

manager:
  replicas: ${DRAGONFLY_MANAGER_REPLICAS}
  image:
    repository: ${DRAGONFLY_MANAGER_IMAGE_REPOSITORY}
    tag: ${DRAGONFLY_MANAGER_IMAGE_TAG}
  initContainer:
    image:
      repository: ${DRAGONFLY_BUSYBOX_IMAGE_REPOSITORY}
      tag: ${DRAGONFLY_BUSYBOX_IMAGE_TAG}
  nodeSelector:
${system_node_selector_yaml}
  metrics:
    enable: true
    serviceMonitor:
      enable: true

scheduler:
  replicas: ${DRAGONFLY_SCHEDULER_REPLICAS}
  image:
    repository: ${DRAGONFLY_SCHEDULER_IMAGE_REPOSITORY}
    tag: ${DRAGONFLY_SCHEDULER_IMAGE_TAG}
  initContainer:
    image:
      repository: ${DRAGONFLY_BUSYBOX_IMAGE_REPOSITORY}
      tag: ${DRAGONFLY_BUSYBOX_IMAGE_TAG}
  nodeSelector:
${system_node_selector_yaml}
  metrics:
    enable: true
    serviceMonitor:
      enable: true

seedClient:
  replicas: ${DRAGONFLY_SEED_CLIENT_REPLICAS}
  image:
    repository: ${DRAGONFLY_CLIENT_IMAGE_REPOSITORY}
    tag: ${DRAGONFLY_CLIENT_IMAGE_TAG}
  initContainer:
    image:
      repository: ${DRAGONFLY_BUSYBOX_IMAGE_REPOSITORY}
      tag: ${DRAGONFLY_BUSYBOX_IMAGE_TAG}
  nodeSelector:
${seed_workload_node_selector_yaml}
  tolerations:
${workload_tolerations_yaml}
  affinity:
${seed_client_affinity_yaml}
  persistence:
    enable: false
  metrics:
    enable: true
    serviceMonitor:
      enable: true

client:
  image:
    repository: ${DRAGONFLY_CLIENT_IMAGE_REPOSITORY}
    tag: ${DRAGONFLY_CLIENT_IMAGE_TAG}
  initContainer:
    image:
      repository: ${DRAGONFLY_BUSYBOX_IMAGE_REPOSITORY}
      tag: ${DRAGONFLY_BUSYBOX_IMAGE_TAG}
  nodeSelector:
${workload_node_selector_yaml}
  tolerations:
${workload_tolerations_yaml}
  dfinit:
    enable: false
  metrics:
    enable: true
    serviceMonitor:
      enable: true

mysql:
  enable: true
  image:
    repository: ${DRAGONFLY_MYSQL_IMAGE_REPOSITORY}
    tag: ${DRAGONFLY_MYSQL_IMAGE_TAG}

redis:
  enable: true
  image:
    repository: ${DRAGONFLY_REDIS_IMAGE_REPOSITORY}
    tag: ${DRAGONFLY_REDIS_IMAGE_TAG}
EOF

printf '%s\n' "${containerd_configurer_script}" >"${tmp_containerd_config_dir}/configure-containerd.sh"
printf '%s\n' "${containerd_registry_dropin_toml}" >"${tmp_containerd_config_dir}/10-dragonfly-registry.toml"

python3 - <<'PY' "${tmp_containerd_config_dir}" "${containerd_registry_hosts_files}"
import pathlib
import sys

target_dir = pathlib.Path(sys.argv[1])
payload = sys.argv[2]
current_name = None
current_lines = []

def flush_file() -> None:
    global current_name, current_lines
    if current_name is None:
        return
    (target_dir / current_name).write_text("\n".join(current_lines) + "\n", encoding="utf-8")

for raw_line in payload.splitlines():
    if raw_line.startswith("FILE:"):
        flush_file()
        current_name = raw_line[5:]
        current_lines = []
        continue
    current_lines.append(raw_line)

flush_file()
PY

kubectl -n "${DRAGONFLY_NAMESPACE}" create configmap "${DRAGONFLY_CONTAINERD_CONFIG_CONFIGMAP_NAME}" \
  --from-file="${tmp_containerd_config_dir}" \
  --dry-run=client \
  -o yaml | kubectl apply -f - >/dev/null

cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: ${DRAGONFLY_CONTAINERD_CONFIG_DAEMONSET_NAME}
  namespace: ${DRAGONFLY_NAMESPACE}
spec:
  selector:
    matchLabels:
      app: ${DRAGONFLY_CONTAINERD_CONFIG_DAEMONSET_NAME}
  template:
    metadata:
      labels:
        app: ${DRAGONFLY_CONTAINERD_CONFIG_DAEMONSET_NAME}
    spec:
      nodeSelector:
        ${gpu_node_scheduling_key}: ${GPU_NODE_CLASS}
      tolerations:
        - key: ${gpu_node_scheduling_key}
          operator: Equal
          value: ${GPU_NODE_CLASS}
          effect: NoSchedule
        - key: kubernetes.azure.com/scalesetpriority
          operator: Equal
          value: spot
          effect: NoSchedule
        - key: nvidia.com/gpu
          operator: Exists
          effect: NoSchedule
      initContainers:
        - name: configure-containerd
          image: ${ACR_LOGIN_SERVER}/${DRAGONFLY_BUSYBOX_IMAGE_REPOSITORY}:${DRAGONFLY_BUSYBOX_IMAGE_TAG}
          imagePullPolicy: IfNotPresent
          command:
            - /bin/sh
            - /config/configure-containerd.sh
          securityContext:
            privileged: true
          volumeMounts:
            - name: config
              mountPath: /config
            - name: host-containerd-conf
              mountPath: /host/etc/containerd/conf.d
            - name: host-containerd-certs
              mountPath: /host/etc/containerd/certs.d
      containers:
        - name: hold
          image: ${ACR_LOGIN_SERVER}/${DRAGONFLY_BUSYBOX_IMAGE_REPOSITORY}:${DRAGONFLY_BUSYBOX_IMAGE_TAG}
          imagePullPolicy: IfNotPresent
          command:
            - /bin/sh
            - -c
            - trap 'exit 0' TERM INT; sleep 3600 & wait
      volumes:
        - name: config
          configMap:
            name: ${DRAGONFLY_CONTAINERD_CONFIG_CONFIGMAP_NAME}
            defaultMode: 0755
        - name: host-containerd-conf
          hostPath:
            path: /etc/containerd/conf.d
            type: DirectoryOrCreate
        - name: host-containerd-certs
          hostPath:
            path: /etc/containerd/certs.d
            type: DirectoryOrCreate
EOF

kubectl -n "${DRAGONFLY_NAMESPACE}" rollout restart daemonset/${DRAGONFLY_CONTAINERD_CONFIG_DAEMONSET_NAME} >/dev/null 2>&1 || true

log "Installing Dragonfly from ${DRAGONFLY_CHART_FILE}"
log "Dragonfly will configure containerd registry hosts for ${ACR_LOGIN_SERVER} and ${DRAGONFLY_CONTAINERD_REGISTRIES_CSV:-docker.io,ghcr.io,nvcr.io}"
log "On Ubuntu2404/containerd v3 nodes, containerd is configured through /etc/containerd/conf.d + /etc/containerd/certs.d so it can coexist with NVIDIA toolkit drop-ins."

helm upgrade --install "${DRAGONFLY_RELEASE_NAME}" \
  "${DRAGONFLY_CHART_FILE}" \
  --namespace "${DRAGONFLY_NAMESPACE}" \
  --create-namespace \
  --reset-values \
  -f "${tmp_values_file}" \
  --wait \
  --timeout 15m

kubectl -n "${DRAGONFLY_NAMESPACE}" rollout status deployment/${DRAGONFLY_RELEASE_NAME}-manager --timeout=10m
kubectl -n "${DRAGONFLY_NAMESPACE}" rollout status statefulset/${DRAGONFLY_RELEASE_NAME}-scheduler --timeout=10m
kubectl -n "${DRAGONFLY_NAMESPACE}" rollout status statefulset/${DRAGONFLY_RELEASE_NAME}-seed-client --timeout=10m
kubectl -n "${DRAGONFLY_NAMESPACE}" rollout status daemonset/${DRAGONFLY_RELEASE_NAME}-client --timeout=10m
kubectl -n "${DRAGONFLY_NAMESPACE}" rollout status daemonset/${DRAGONFLY_CONTAINERD_CONFIG_DAEMONSET_NAME} --timeout=10m

DRAGONFLY_NAMESPACE="${DRAGONFLY_NAMESPACE}" \
  bash "${ROOT_DIR}/01-environment/scripts/apply-azmonitor-servicemonitors.sh"

log "Dragonfly deployment completed"
log "  namespace     : ${DRAGONFLY_NAMESPACE}"
log "  release       : ${DRAGONFLY_RELEASE_NAME}"
log "  image registry: ${ACR_LOGIN_SERVER}"
log "  system ctrl   : ${SYSTEM_POOL_NAME}"
log "  gpu selector  : ${gpu_node_scheduling_key}=${GPU_NODE_CLASS}"
log "  seed peers    : ${gpu_node_scheduling_key}=${GPU_NODE_CLASS}, capacity-type=on-demand, replicas=${DRAGONFLY_SEED_CLIENT_REPLICAS}"
log "  client scope  : ${gpu_node_scheduling_key}=${GPU_NODE_CLASS}"
log "  runtime hook  : ${DRAGONFLY_CONTAINERD_CONFIG_DAEMONSET_NAME} via /etc/containerd/conf.d + /etc/containerd/certs.d"
log ""
kubectl -n "${DRAGONFLY_NAMESPACE}" get pods -o wide
