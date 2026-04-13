#!/usr/bin/env bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/common.sh"

need_cmd kubectl

[[ -n "${KUBECONFIG_FILE:-}" ]] || fail "KUBECONFIG_FILE is required"
[[ -n "${AZURE_SUBSCRIPTION_ID:-}" ]] || fail "AZURE_SUBSCRIPTION_ID is required"
[[ -n "${RESOURCE_GROUP:-}" ]] || fail "RESOURCE_GROUP is required"
[[ -n "${CLUSTER_NAME:-}" ]] || fail "CLUSTER_NAME is required"
[[ -n "${AMA_METRICS_CONFIG_FILE:-}" ]] || fail "AMA_METRICS_CONFIG_FILE is required"
[[ -f "${AMA_METRICS_CONFIG_FILE}" ]] || fail "AMA metrics config file not found: ${AMA_METRICS_CONFIG_FILE}"

refresh_aks_kubeconfig
wait_for_cluster_api

log "Applying AMA metrics ConfigMap from ${AMA_METRICS_CONFIG_FILE}"
kubectl apply -f "${AMA_METRICS_CONFIG_FILE}" >/dev/null