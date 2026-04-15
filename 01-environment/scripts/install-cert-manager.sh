#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENVIRONMENT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
CERT_MANAGER_NAMESPACE="cert-manager"
CERT_MANAGER_MANIFEST_FILE="${ENVIRONMENT_DIR}/charts/cert-manager.yaml"
CERT_MANAGER_INGRESS_CLASS_TEMPLATE_FILE="${ENVIRONMENT_DIR}/charts/istio-ingressclass.yaml"
CERT_MANAGER_ISSUER_TEMPLATE_FILE="${ENVIRONMENT_DIR}/charts/letencrypt-signer.yaml"

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

wait_for_service() {
  local namespace="$1"
  local name="$2"
  local attempts="${3:-60}"
  local attempt

  for attempt in $(seq 1 "${attempts}"); do
    if kubectl get service "${name}" -n "${namespace}" >/dev/null 2>&1; then
      return 0
    fi

    warn "Waiting for service ${namespace}/${name} (${attempt}/${attempts})"
    sleep 10
  done

  fail "Service ${namespace}/${name} was not created in time"
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

wait_for_deployment_rollout() {
  local namespace="$1"
  local name="$2"

  kubectl rollout status deployment/"${name}" -n "${namespace}" --timeout=10m >/dev/null
}

render_template() {
  local template_file="$1"
  local output_file="$2"

  python3 - "${template_file}" "${output_file}" <<'PY'
from pathlib import Path
import os
import sys

template = Path(sys.argv[1]).read_text(encoding="utf-8")
replacements = {
    "__CERT_MANAGER_ACME_EMAIL__": os.environ["CERT_MANAGER_ACME_EMAIL"],
    "__CERT_MANAGER_INGRESS_CLASS_NAME__": os.environ["CERT_MANAGER_INGRESS_CLASS_NAME"],
    "__CERT_MANAGER_STAGING_ISSUER_NAME__": os.environ["CERT_MANAGER_STAGING_ISSUER_NAME"],
    "__CERT_MANAGER_PROD_ISSUER_NAME__": os.environ["CERT_MANAGER_PROD_ISSUER_NAME"],
}

for old, new in replacements.items():
    template = template.replace(old, new)

Path(sys.argv[2]).write_text(template, encoding="utf-8")
PY
}

wait_for_clusterissuer_ready() {
  local name="$1"
  local attempts="${2:-60}"
  local attempt
  local ready
  local message

  for attempt in $(seq 1 "${attempts}"); do
    ready="$(kubectl get clusterissuer "${name}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
    if [[ "${ready}" == "True" ]]; then
      return 0
    fi

    message="$(kubectl get clusterissuer "${name}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].message}' 2>/dev/null || true)"
    warn "Waiting for ClusterIssuer ${name} to become Ready (${attempt}/${attempts}) ${message}"
    sleep 10
  done

  kubectl describe clusterissuer "${name}" >&2 || true
  fail "ClusterIssuer ${name} did not become Ready in time"
}

need_cmd az
need_cmd kubectl
need_cmd python3

require_env \
  KUBECONFIG_FILE AZURE_SUBSCRIPTION_ID RESOURCE_GROUP CLUSTER_NAME \
  CERT_MANAGER_ACME_EMAIL CERT_MANAGER_INGRESS_CLASS_NAME \
  CERT_MANAGER_STAGING_ISSUER_NAME CERT_MANAGER_PROD_ISSUER_NAME \
  CERT_MANAGER_INGRESS_GATEWAY_NAMESPACE CERT_MANAGER_INGRESS_GATEWAY_SERVICE_NAME

[[ -f "${CERT_MANAGER_MANIFEST_FILE}" ]] || fail "Missing manifest: ${CERT_MANAGER_MANIFEST_FILE}"
[[ -f "${CERT_MANAGER_INGRESS_CLASS_TEMPLATE_FILE}" ]] || fail "Missing manifest template: ${CERT_MANAGER_INGRESS_CLASS_TEMPLATE_FILE}"
[[ -f "${CERT_MANAGER_ISSUER_TEMPLATE_FILE}" ]] || fail "Missing manifest template: ${CERT_MANAGER_ISSUER_TEMPLATE_FILE}"

refresh_kubeconfig
wait_for_cluster_api
wait_for_service "${CERT_MANAGER_INGRESS_GATEWAY_NAMESPACE}" "${CERT_MANAGER_INGRESS_GATEWAY_SERVICE_NAME}"

log "Applying cert-manager manifest"
kubectl apply -f "${CERT_MANAGER_MANIFEST_FILE}" >/dev/null

wait_for_crd clusterissuers.cert-manager.io
wait_for_crd certificates.cert-manager.io
wait_for_deployment_rollout "${CERT_MANAGER_NAMESPACE}" cert-manager
wait_for_deployment_rollout "${CERT_MANAGER_NAMESPACE}" cert-manager-cainjector
wait_for_deployment_rollout "${CERT_MANAGER_NAMESPACE}" cert-manager-webhook

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

render_template "${CERT_MANAGER_INGRESS_CLASS_TEMPLATE_FILE}" "${tmp_dir}/ingressclass.yaml"
render_template "${CERT_MANAGER_ISSUER_TEMPLATE_FILE}" "${tmp_dir}/clusterissuers.yaml"

log "Applying Istio IngressClass"
kubectl apply -f "${tmp_dir}/ingressclass.yaml" >/dev/null

log "Applying Let's Encrypt ClusterIssuers"
kubectl apply -f "${tmp_dir}/clusterissuers.yaml" >/dev/null

wait_for_clusterissuer_ready "${CERT_MANAGER_STAGING_ISSUER_NAME}"
wait_for_clusterissuer_ready "${CERT_MANAGER_PROD_ISSUER_NAME}"

log "cert-manager platform is ready"