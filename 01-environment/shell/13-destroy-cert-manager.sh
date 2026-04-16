#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../../common.sh"

load_env
need_cmd az
need_cmd kubectl

KUBECONFIG_FILE="${AKS_KUBECONFIG_FILE:-$(resolve_aks_kubeconfig_file)}" \
AZURE_SUBSCRIPTION_ID="${AZ_SUBSCRIPTION_ID}" \
RESOURCE_GROUP="${RESOURCE_GROUP}" \
CLUSTER_NAME="${CLUSTER_NAME}" \
CERT_MANAGER_STAGING_ISSUER_NAME="${CERT_MANAGER_STAGING_ISSUER_NAME}" \
CERT_MANAGER_PROD_ISSUER_NAME="${CERT_MANAGER_PROD_ISSUER_NAME}" \
  bash "${SCRIPT_DIR}/../scripts/uninstall-cert-manager.sh"