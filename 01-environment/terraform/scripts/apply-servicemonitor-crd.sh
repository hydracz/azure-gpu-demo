#!/usr/bin/env bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/common.sh"

need_cmd kubectl

[[ -n "${KUBECONFIG_FILE:-}" ]] || fail "KUBECONFIG_FILE is required"
[[ -n "${AZURE_SUBSCRIPTION_ID:-}" ]] || fail "AZURE_SUBSCRIPTION_ID is required"
[[ -n "${RESOURCE_GROUP:-}" ]] || fail "RESOURCE_GROUP is required"
[[ -n "${CLUSTER_NAME:-}" ]] || fail "CLUSTER_NAME is required"
[[ -n "${SERVICE_MONITOR_CRD_FILE:-}" ]] || fail "SERVICE_MONITOR_CRD_FILE is required"
[[ -f "${SERVICE_MONITOR_CRD_FILE}" ]] || fail "ServiceMonitor CRD file not found: ${SERVICE_MONITOR_CRD_FILE}"
if [[ -n "${POD_MONITOR_CRD_FILE:-}" ]]; then
	[[ -f "${POD_MONITOR_CRD_FILE}" ]] || fail "PodMonitor CRD file not found: ${POD_MONITOR_CRD_FILE}"
fi

refresh_aks_kubeconfig
wait_for_cluster_api

log "Applying ServiceMonitor CRD from ${SERVICE_MONITOR_CRD_FILE}"
kubectl apply -f "${SERVICE_MONITOR_CRD_FILE}" --validate=false >/dev/null

if [[ -n "${POD_MONITOR_CRD_FILE:-}" ]]; then
	log "Applying PodMonitor CRD from ${POD_MONITOR_CRD_FILE}"
	kubectl apply -f "${POD_MONITOR_CRD_FILE}" --validate=false >/dev/null
fi