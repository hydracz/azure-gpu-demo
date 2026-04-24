#!/usr/bin/env bash

set -euo pipefail

log() {
  printf '[gateway-api] %s\n' "$*"
}

warn() {
  printf '[gateway-api][warn] %s\n' "$*" >&2
}

fail() {
  printf '[gateway-api][error] %s\n' "$*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "missing required command: $1"
}

require_env() {
  local name

  for name in "$@"; do
    [[ -n "${!name:-}" ]] || fail "${name} is required"
  done
}

action="${MANAGED_GATEWAY_API_ACTION:-ensure}"

ensure_parent_dir() {
  local target_path="$1"

  mkdir -p "$(dirname "${target_path}")"
}

kubeconfig_file_exists() {
  [[ -s "${KUBECONFIG_FILE}" ]]
}

refresh_kubeconfig() {
  ensure_parent_dir "${KUBECONFIG_FILE}"

  if kubeconfig_file_exists; then
    export KUBECONFIG="${KUBECONFIG_FILE}"
    log "Reusing existing kubeconfig ${KUBECONFIG_FILE} for ${CLUSTER_NAME}"
    return 0
  fi

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

    warn "Kubernetes API not ready yet (${attempt}/30)"
    sleep 10
  done

  fail "Kubernetes API did not become ready in time"
}

ensure_aks_preview_extension() {
  if az extension show --name aks-preview --only-show-errors >/dev/null 2>&1; then
    log "Updating Azure CLI extension aks-preview"
    az extension update --name aks-preview --only-show-errors >/dev/null
  else
    log "Installing Azure CLI extension aks-preview"
    az extension add --name aks-preview --only-show-errors >/dev/null
  fi
}

wait_for_feature_registration() {
  local feature_name="$1"
  local attempt
  local state

  state="$(az feature show --namespace Microsoft.ContainerService --name "${feature_name}" --query properties.state -o tsv --only-show-errors 2>/dev/null || true)"
  if [[ "${state}" != "Registered" ]]; then
    log "Registering Azure feature Microsoft.ContainerService/${feature_name}"
    az feature register --namespace Microsoft.ContainerService --name "${feature_name}" --only-show-errors >/dev/null
  fi

  for attempt in $(seq 1 40); do
    state="$(az feature show --namespace Microsoft.ContainerService --name "${feature_name}" --query properties.state -o tsv --only-show-errors 2>/dev/null || true)"
    if [[ "${state}" == "Registered" ]]; then
      return 0
    fi

    warn "Waiting for Azure feature ${feature_name} to register (${attempt}/40); current state=${state:-unknown}"
    sleep 15
  done

  fail "Azure feature ${feature_name} did not reach Registered state in time"
}

wait_for_crd() {
  local name="$1"
  local attempts="${2:-60}"
  local attempt

  for attempt in $(seq 1 "${attempts}"); do
    if kubectl get crd "${name}" >/dev/null 2>&1; then
      return 0
    fi

    warn "Waiting for CRD ${name} (${attempt}/${attempts})"
    sleep 10
  done

  fail "CRD ${name} was not created in time"
}

wait_for_gatewayclass() {
  local name="$1"
  local attempts="${2:-60}"
  local attempt

  for attempt in $(seq 1 "${attempts}"); do
    if kubectl get gatewayclass "${name}" >/dev/null 2>&1; then
      return 0
    fi

    warn "Waiting for GatewayClass ${name} (${attempt}/${attempts})"
    sleep 10
  done

  fail "GatewayClass ${name} was not created in time"
}

wait_for_configmap() {
  local namespace="$1"
  local name="$2"
  local attempts="${3:-60}"
  local attempt

  for attempt in $(seq 1 "${attempts}"); do
    if kubectl get configmap "${name}" -n "${namespace}" >/dev/null 2>&1; then
      return 0
    fi

    warn "Waiting for ConfigMap ${namespace}/${name} (${attempt}/${attempts})"
    sleep 10
  done

  fail "ConfigMap ${namespace}/${name} was not created in time"
}

managed_gateway_api_installed() {
  [[ "$(kubectl get crd gateways.gateway.networking.k8s.io -o jsonpath='{.metadata.annotations.app\.kubernetes\.io/managed-by}' 2>/dev/null || true)" == "aks" ]]
}

enable_managed_gateway_api() {
  if managed_gateway_api_installed; then
    log "AKS managed Gateway API CRDs already present"
    return 0
  fi

  log "Enabling AKS managed Gateway API on cluster ${CLUSTER_NAME}"
  az aks update \
    --resource-group "${RESOURCE_GROUP}" \
    --name "${CLUSTER_NAME}" \
    --enable-gateway-api \
    --only-show-errors \
    >/dev/null
}

need_cmd az
need_cmd kubectl

require_env \
  KUBECONFIG_FILE AZURE_SUBSCRIPTION_ID RESOURCE_GROUP CLUSTER_NAME AKS_MANAGED_GATEWAY_API_ENABLED

if [[ "${AKS_MANAGED_GATEWAY_API_ENABLED}" != "true" ]]; then
  log "AKS_MANAGED_GATEWAY_API_ENABLED=false, skipping managed Gateway API enablement"
  exit 0
fi

case "${action}" in
  ensure|register|wait)
    ;;
  *)
    fail "Unsupported MANAGED_GATEWAY_API_ACTION: ${action}"
    ;;
esac

if [[ "${action}" == "ensure" || "${action}" == "register" ]]; then
  ensure_aks_preview_extension
  wait_for_feature_registration ManagedGatewayAPIPreview

  log "Refreshing Microsoft.ContainerService provider registration"
  az provider register --namespace Microsoft.ContainerService --wait --only-show-errors >/dev/null
fi

if [[ "${action}" == "register" ]]; then
  log "Managed Gateway API prerequisites are ready"
  exit 0
fi

refresh_kubeconfig
wait_for_cluster_api

if [[ "${action}" == "ensure" ]]; then
  enable_managed_gateway_api
fi

wait_for_crd gatewayclasses.gateway.networking.k8s.io
wait_for_crd gateways.gateway.networking.k8s.io
wait_for_crd httproutes.gateway.networking.k8s.io
wait_for_crd referencegrants.gateway.networking.k8s.io
wait_for_gatewayclass istio

if [[ "${ISTIO_SERVICE_MESH_ENABLED:-false}" == "true" ]]; then
  wait_for_configmap aks-istio-system istio-gateway-class-defaults
fi

log "AKS managed Gateway API is ready"