#!/usr/bin/env bash

set -euo pipefail

log() {
  printf '[terraform] %s\n' "$*"
}

warn() {
  printf '[terraform][warn] %s\n' "$*" >&2
}

fail() {
  printf '[terraform][error] %s\n' "$*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "missing required command: $1"
}

ensure_parent_dir() {
  local target_path="$1"
  local target_dir

  target_dir="$(dirname "${target_path}")"
  mkdir -p "${target_dir}"
}

refresh_aks_kubeconfig() {
  need_cmd az
  need_cmd kubectl

  [[ -n "${KUBECONFIG_FILE:-}" ]] || fail "KUBECONFIG_FILE is required"
  [[ -n "${AZURE_SUBSCRIPTION_ID:-}" ]] || fail "AZURE_SUBSCRIPTION_ID is required"
  [[ -n "${RESOURCE_GROUP:-}" ]] || fail "RESOURCE_GROUP is required"
  [[ -n "${CLUSTER_NAME:-}" ]] || fail "CLUSTER_NAME is required"

  ensure_parent_dir "${KUBECONFIG_FILE}"
  az account set --subscription "${AZURE_SUBSCRIPTION_ID}" --only-show-errors >/dev/null

  if az aks get-credentials \
    --resource-group "${RESOURCE_GROUP}" \
    --name "${CLUSTER_NAME}" \
    --file "${KUBECONFIG_FILE}" \
    --overwrite-existing \
    --admin \
    --only-show-errors >/dev/null 2>&1; then
    log "Fetched AKS admin kubeconfig for ${CLUSTER_NAME}"
  else
    warn "Falling back to user kubeconfig for ${CLUSTER_NAME}"
    az aks get-credentials \
      --resource-group "${RESOURCE_GROUP}" \
      --name "${CLUSTER_NAME}" \
      --file "${KUBECONFIG_FILE}" \
      --overwrite-existing \
      --only-show-errors >/dev/null
  fi

  export KUBECONFIG="${KUBECONFIG_FILE}"
}

wait_for_cluster_api() {
  local attempt

  for attempt in $(seq 1 30); do
    if kubectl cluster-info >/dev/null 2>&1; then
      return 0
    fi

    warn "Kubernetes API not ready yet for ${CLUSTER_NAME:-cluster}; retry ${attempt}/30"
    sleep 10
  done

  fail "Kubernetes API for ${CLUSTER_NAME:-cluster} did not become ready in time"
}