#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENVIRONMENT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
CERT_MANAGER_MANIFEST_FILE="${ENVIRONMENT_DIR}/charts/cert-manager.yaml"

log() {
  printf '[cert-manager] %s\n' "$*"
}

warn() {
  printf '[cert-manager][warn] %s\n' "$*" >&2
}

fail() {
  printf '[cert-manager][error] %s\n' "$*" >&2
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

refresh_kubeconfig() {
  az account set --subscription "${AZURE_SUBSCRIPTION_ID}" --only-show-errors >/dev/null
  az aks get-credentials \
    --resource-group "${RESOURCE_GROUP}" \
    --name "${CLUSTER_NAME}" \
    --file "${KUBECONFIG_FILE}" \
    --overwrite-existing \
    --only-show-errors >/dev/null 2>&1 || return 1

  export KUBECONFIG="${KUBECONFIG_FILE}"
}

need_cmd az
need_cmd kubectl

require_env \
  KUBECONFIG_FILE AZURE_SUBSCRIPTION_ID RESOURCE_GROUP CLUSTER_NAME \
  CERT_MANAGER_INGRESS_CLASS_NAME CERT_MANAGER_STAGING_ISSUER_NAME CERT_MANAGER_PROD_ISSUER_NAME

if ! refresh_kubeconfig; then
  warn "Unable to refresh kubeconfig; AKS cluster may already be deleted"
  exit 0
fi

log "Deleting Let's Encrypt ClusterIssuers"
kubectl delete clusterissuer "${CERT_MANAGER_PROD_ISSUER_NAME}" --ignore-not-found >/dev/null 2>&1 || true
kubectl delete clusterissuer "${CERT_MANAGER_STAGING_ISSUER_NAME}" --ignore-not-found >/dev/null 2>&1 || true

log "Deleting Istio IngressClass"
kubectl delete ingressclass "${CERT_MANAGER_INGRESS_CLASS_NAME}" --ignore-not-found >/dev/null 2>&1 || true

if [[ -f "${CERT_MANAGER_MANIFEST_FILE}" ]]; then
  log "Deleting cert-manager manifest"
  kubectl delete -f "${CERT_MANAGER_MANIFEST_FILE}" --ignore-not-found >/dev/null 2>&1 || true
fi

log "cert-manager platform resources removed"