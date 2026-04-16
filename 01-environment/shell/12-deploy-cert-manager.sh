#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../../common.sh"

load_env
need_cmd az
need_cmd kubectl
need_cmd python3

: "${CERT_MANAGER_ENABLED:=true}"

if [[ "${CERT_MANAGER_ENABLED}" != "true" ]]; then
  log "CERT_MANAGER_ENABLED=false, skipping cert-manager deployment"
  exit 0
fi

require_env \
  AZ_SUBSCRIPTION_ID RESOURCE_GROUP CLUSTER_NAME CERT_MANAGER_ACME_EMAIL \
  CERT_MANAGER_STAGING_ISSUER_NAME CERT_MANAGER_PROD_ISSUER_NAME

KUBECONFIG_FILE="${AKS_KUBECONFIG_FILE:-$(resolve_aks_kubeconfig_file)}" \
AZURE_SUBSCRIPTION_ID="${AZ_SUBSCRIPTION_ID}" \
RESOURCE_GROUP="${RESOURCE_GROUP}" \
CLUSTER_NAME="${CLUSTER_NAME}" \
CERT_MANAGER_ACME_EMAIL="${CERT_MANAGER_ACME_EMAIL}" \
CERT_MANAGER_STAGING_ISSUER_NAME="${CERT_MANAGER_STAGING_ISSUER_NAME}" \
CERT_MANAGER_PROD_ISSUER_NAME="${CERT_MANAGER_PROD_ISSUER_NAME}" \
  bash "${SCRIPT_DIR}/../scripts/install-cert-manager.sh"

write_generated_env CERT_MANAGER_STAGING_ISSUER_NAME "${CERT_MANAGER_STAGING_ISSUER_NAME}"
write_generated_env CERT_MANAGER_PROD_ISSUER_NAME "${CERT_MANAGER_PROD_ISSUER_NAME}"

log "cert-manager deployment completed"