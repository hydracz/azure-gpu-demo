#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../../common.sh"

load_env
ensure_tooling
ensure_aks_kubeconfig

require_env \
  DRAGONFLY_NAMESPACE DRAGONFLY_CACHE_WARMER_NAME DRAGONFLY_WORKLOAD_LABEL DRAGONFLY_SEED_NODE_ROLE_LABEL \
  ACR_LOGIN_SERVER QWEN_LOADTEST_TARGET_REPOSITORY QWEN_LOADTEST_SOURCE_IMAGE_TAG DRAGONFLY_PREFETCH_HOLD_SECONDS \
  DRAGONFLY_PREFETCH_NODE_COUNT

prefetch_image="${DRAGONFLY_PREFETCH_IMAGE:-${QWEN_LOADTEST_TARGET_IMAGE:-${ACR_LOGIN_SERVER}/${QWEN_LOADTEST_TARGET_REPOSITORY}:${QWEN_LOADTEST_SOURCE_IMAGE_TAG}}}"
prefetch_image_pull_policy="${DRAGONFLY_PREFETCH_IMAGE_PULL_POLICY:-IfNotPresent}"
prefetch_cpu_request="${DRAGONFLY_PREFETCH_CPU_REQUEST:-10m}"
prefetch_memory_request="${DRAGONFLY_PREFETCH_MEMORY_REQUEST:-16Mi}"
prefetch_ephemeral_storage_request="${DRAGONFLY_PREFETCH_EPHEMERAL_STORAGE_REQUEST:-32Mi}"
prefetch_ready_timeout_seconds="${DRAGONFLY_PREFETCH_READY_TIMEOUT_SECONDS:-600}"

[[ "${DRAGONFLY_PREFETCH_HOLD_SECONDS}" =~ ^[0-9]+$ ]] || fail "DRAGONFLY_PREFETCH_HOLD_SECONDS must be an integer"
[[ "${DRAGONFLY_PREFETCH_NODE_COUNT}" =~ ^[0-9]+$ ]] || fail "DRAGONFLY_PREFETCH_NODE_COUNT must be an integer"
[[ "${prefetch_ready_timeout_seconds}" =~ ^[0-9]+$ ]] || fail "DRAGONFLY_PREFETCH_READY_TIMEOUT_SECONDS must be an integer"

collect_cache_warmer_status() {
  kubectl -n "${DRAGONFLY_NAMESPACE}" get pods \
    -l "app=${DRAGONFLY_CACHE_WARMER_NAME}" \
    --field-selector=status.phase!=Failed \
  -o json | python3 -c '
import json
import sys

data = json.load(sys.stdin)
items = data.get("items", [])
total = 0
ready = 0
waiting = 0

for item in items:
  total += 1
  statuses = item.get("status", {}).get("containerStatuses", [])
  if statuses and all(status.get("ready", False) for status in statuses):
    ready += 1
  else:
    waiting += 1

print(f"{total} {ready} {waiting}")
'
}

print_cache_warmer_diagnostics() {
  kubectl -n "${DRAGONFLY_NAMESPACE}" get pods -l "app=${DRAGONFLY_CACHE_WARMER_NAME}" -o wide || true
  kubectl get nodes -l "workload=${DRAGONFLY_WORKLOAD_LABEL},gpu-role=${DRAGONFLY_SEED_NODE_ROLE_LABEL}" || true
}

log "Warming Dragonfly cache on seed workload nodes"
log "  namespace  : ${DRAGONFLY_NAMESPACE}"
log "  daemonset  : ${DRAGONFLY_CACHE_WARMER_NAME}"
log "  image      : ${prefetch_image}"
log "  pullPolicy : ${prefetch_image_pull_policy}"
log "  selector   : workload=${DRAGONFLY_WORKLOAD_LABEL}, gpu-role=${DRAGONFLY_SEED_NODE_ROLE_LABEL}"

kubectl -n "${DRAGONFLY_NAMESPACE}" delete pods \
  -l "app=${DRAGONFLY_CACHE_WARMER_NAME}" \
  --field-selector=status.phase=Failed \
  --ignore-not-found >/dev/null 2>&1 || true

cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: ${DRAGONFLY_CACHE_WARMER_NAME}
  namespace: ${DRAGONFLY_NAMESPACE}
  labels:
    app: ${DRAGONFLY_CACHE_WARMER_NAME}
spec:
  selector:
    matchLabels:
      app: ${DRAGONFLY_CACHE_WARMER_NAME}
  updateStrategy:
    type: RollingUpdate
  template:
    metadata:
      labels:
        app: ${DRAGONFLY_CACHE_WARMER_NAME}
    spec:
      nodeSelector:
        workload: ${DRAGONFLY_WORKLOAD_LABEL}
        gpu-role: ${DRAGONFLY_SEED_NODE_ROLE_LABEL}
      tolerations:
        - key: kubernetes.azure.com/scalesetpriority
          operator: Equal
          value: spot
          effect: NoSchedule
        - key: workload
          operator: Exists
          effect: NoSchedule
        - key: nvidia.com/gpu
          operator: Exists
          effect: NoSchedule
      terminationGracePeriodSeconds: 0
      containers:
        - name: image-warmer
          image: ${prefetch_image}
          imagePullPolicy: ${prefetch_image_pull_policy}
          resources:
            requests:
              cpu: ${prefetch_cpu_request}
              memory: ${prefetch_memory_request}
              ephemeral-storage: ${prefetch_ephemeral_storage_request}
          command:
            - /bin/sh
            - -c
            - trap 'exit 0' TERM INT; sleep ${DRAGONFLY_PREFETCH_HOLD_SECONDS} & wait
EOF

kubectl -n "${DRAGONFLY_NAMESPACE}" rollout status daemonset/${DRAGONFLY_CACHE_WARMER_NAME} --timeout=30m

deadline="$(( $(date +%s) + prefetch_ready_timeout_seconds ))"
while true; do
  kubectl -n "${DRAGONFLY_NAMESPACE}" delete pods \
    -l "app=${DRAGONFLY_CACHE_WARMER_NAME}" \
    --field-selector=status.phase=Failed \
    --ignore-not-found >/dev/null 2>&1 || true

  read -r current_count ready_count waiting_count <<<"$(collect_cache_warmer_status)"
  if [[ "${current_count}" == "${DRAGONFLY_PREFETCH_NODE_COUNT}" && "${ready_count}" == "${DRAGONFLY_PREFETCH_NODE_COUNT}" ]]; then
    break
  fi

  if (( $(date +%s) >= deadline )); then
    log "Dragonfly cache warmer did not become Ready on all seed workload nodes within ${prefetch_ready_timeout_seconds}s"
    print_cache_warmer_diagnostics
    fail "Cache warmer pods are not healthy; see status above"
  fi

  sleep 10
done

log "Dragonfly cache warmer is ready on seed workload nodes"
kubectl -n "${DRAGONFLY_NAMESPACE}" get pods -l app=${DRAGONFLY_CACHE_WARMER_NAME} -o wide
