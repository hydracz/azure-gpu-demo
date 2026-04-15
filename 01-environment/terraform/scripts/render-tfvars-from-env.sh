#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TERRAFORM_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../../../common.sh"

ENV_NAME="${1:-}"
OUTPUT_FILE="${2:-}"

if [[ -z "${ENV_NAME}" ]]; then
  echo "usage: ./scripts/render-tfvars-from-env.sh <env-name> [output-file]"
  exit 1
fi

if [[ -z "${OUTPUT_FILE}" ]]; then
  OUTPUT_FILE="${TERRAFORM_DIR}/${ENV_NAME}.auto.tfvars.json"
fi

load_env
ensure_parent_dir "${OUTPUT_FILE}"

is_true() {
    case "${1:-}" in
        1|true|TRUE|yes|YES|on|ON)
            return 0
            ;;
    esac

    return 1
}

require_prepared_var() {
    local name="$1"

    [[ -n "${!name:-}" ]] || fail "${name} is required from 00-prepare output. Run ./00-prepare/00-prepare.sh first."
}

if [[ -z "${GRAFANA_ADMIN_PRINCIPAL_IDS:-}" ]]; then
    export GRAFANA_ADMIN_PRINCIPAL_IDS="$(resolve_current_azure_principal_id)"
fi

existing_subnet_id="${EXISTING_VNET_SUBNET_ID:-}"

if [[ -z "${existing_subnet_id}" ]]; then
    fail "EXISTING_VNET_SUBNET_ID is required. Run ./00-prepare/00-prepare.sh first so 01-environment consumes a prepared subnet instead of creating one."
fi

need_cmd az
if ! az resource show --ids "${existing_subnet_id}" --query id -o tsv --only-show-errors >/dev/null 2>&1; then
    fail "EXISTING_VNET_SUBNET_ID does not exist: ${existing_subnet_id}. Run ./00-prepare/00-prepare.sh first or point it to an existing subnet."
fi

existing_acr_id="${EXISTING_ACR_ID:-}"
if [[ -z "${existing_acr_id}" ]]; then
    fail "EXISTING_ACR_ID is required. Run ./00-prepare/00-prepare.sh first so 01-environment consumes a prepared ACR instead of creating one."
fi

if ! az resource show --ids "${existing_acr_id}" --query id -o tsv --only-show-errors >/dev/null 2>&1; then
    fail "EXISTING_ACR_ID does not exist: ${existing_acr_id}. Run ./00-prepare/00-prepare.sh first or point it to an existing ACR."
fi

require_prepared_var KARPENTER_TARGET_IMAGE_REPOSITORY

if is_true "${GPU_OPERATOR_ENABLED:-true}"; then
    require_prepared_var GPU_DRIVER_TARGET_REPOSITORY
    require_prepared_var GPU_OPERATOR_MIRROR_NVIDIA_REPOSITORY
    require_prepared_var GPU_OPERATOR_MIRROR_NVIDIA_CLOUD_NATIVE_REPOSITORY
    require_prepared_var GPU_OPERATOR_MIRROR_NVIDIA_K8S_REPOSITORY
    require_prepared_var GPU_OPERATOR_MIRROR_NFD_REPOSITORY
fi

if is_true "${ISTIO_SERVICE_MESH_ENABLED:-true}" && is_true "${ISTIO_KIALI_ENABLED:-true}"; then
    require_prepared_var ISTIO_KIALI_OPERATOR_TARGET_IMAGE_REPOSITORY
    require_prepared_var ISTIO_KIALI_TARGET_IMAGE_NAME
    require_prepared_var ISTIO_KIALI_PROXY_TARGET_IMAGE
    require_prepared_var ISTIO_KIALI_IMAGE_TAG
fi

python3 - "${OUTPUT_FILE}" <<'PY'
import json
import os
import sys
from pathlib import Path


def require(name: str) -> str:
    value = os.getenv(name, "").strip()
    if not value:
        raise SystemExit(f"{name} is required")
    return value


def get(name: str, default: str = "") -> str:
    return os.getenv(name, default).strip()


def as_bool(name: str, default: bool) -> bool:
    raw = get(name)
    if raw == "":
        return default
    normalized = raw.lower()
    if normalized in {"1", "true", "yes", "y", "on"}:
        return True
    if normalized in {"0", "false", "no", "n", "off"}:
        return False
    raise SystemExit(f"{name} must be a boolean string, got: {raw}")


def as_int(name: str, default: int) -> int:
    raw = get(name)
    if raw == "":
        return default
    return int(raw)


def csv_list(name: str) -> list[str]:
    raw = get(name)
    if raw == "":
        return []
    return [item.strip() for item in raw.split(",") if item.strip()]


output_path = Path(sys.argv[1])
existing_subnet_id = get("EXISTING_VNET_SUBNET_ID")
existing_acr_id = require("EXISTING_ACR_ID")
cert_manager_enabled = as_bool("CERT_MANAGER_ENABLED", True)
cert_manager_acme_email = get("CERT_MANAGER_ACME_EMAIL")

if cert_manager_enabled and cert_manager_acme_email == "":
    raise SystemExit("CERT_MANAGER_ACME_EMAIL is required when CERT_MANAGER_ENABLED is true")

tags = {
    "environment": get("TAGS_ENVIRONMENT", "dev"),
    "owner": get("TAGS_OWNER", "platform"),
}

payload = {
    "subscription_id": require("AZ_SUBSCRIPTION_ID"),
    "location": require("LOCATION"),
    "resource_group_name": require("RESOURCE_GROUP"),
    "cluster_name": require("CLUSTER_NAME"),
    "aks_identity_name": get("AKS_IDENTITY_NAME", "id-aks-control-plane"),
    "existing_acr_id": existing_acr_id,
    "monitor_workspace_name": require("MONITOR_WORKSPACE_NAME"),
    "monitor_workspace_public_network_access_enabled": as_bool("MONITOR_WORKSPACE_PUBLIC_NETWORK_ACCESS_ENABLED", True),
    "log_analytics_workspace_name": require("LOG_ANALYTICS_WORKSPACE_NAME"),
    "grafana_name": require("GRAFANA_NAME"),
    "grafana_major_version": as_int("GRAFANA_MAJOR_VERSION", 12),
    "grafana_dashboard_import_enabled": as_bool("GRAFANA_DASHBOARD_IMPORT_ENABLED", True),
    "diagnostic_setting_name": get("AKS_DIAGNOSTIC_SETTING_NAME", "aks-all-logs"),
    "existing_subnet_id": existing_subnet_id,
    "system_pool_name": get("SYSTEM_POOL_NAME", "sysd4"),
    "system_vm_size": get("SYSTEM_VM_SIZE", "Standard_D4ads_v6"),
    "system_node_count": as_int("SYSTEM_NODE_COUNT", 3),
    "aks_admin_username": get("AKS_ADMIN_USERNAME", "azureuser"),
    "service_cidr": get("SERVICE_CIDR", "172.16.32.0/19"),
    "dns_service_ip": get("DNS_SERVICE_IP", "172.16.32.10"),
    "blob_driver_enabled": as_bool("AKS_ENABLE_BLOB_DRIVER", True),
    "istio_service_mesh_enabled": as_bool("ISTIO_SERVICE_MESH_ENABLED", True),
    "istio_revisions": csv_list("ISTIO_REVISIONS_CSV") or ["asm-1-27"],
    "istio_internal_ingress_gateway_enabled": as_bool("ISTIO_INTERNAL_INGRESS_GATEWAY_ENABLED", True),
    "istio_external_ingress_gateway_enabled": as_bool("ISTIO_EXTERNAL_INGRESS_GATEWAY_ENABLED", True),
    "cert_manager_enabled": cert_manager_enabled,
    "cert_manager_acme_email": cert_manager_acme_email,
    "cert_manager_ingress_class_name": get("CERT_MANAGER_INGRESS_CLASS_NAME", "istio"),
    "cert_manager_staging_issuer_name": get("CERT_MANAGER_STAGING_ISSUER_NAME", "letsencrypt-staging"),
    "cert_manager_prod_issuer_name": get("CERT_MANAGER_PROD_ISSUER_NAME", "letsencrypt-prod"),
    "cert_manager_ingress_gateway_namespace": get("CERT_MANAGER_INGRESS_GATEWAY_NAMESPACE", "aks-istio-ingress"),
    "cert_manager_ingress_gateway_service_name": get("CERT_MANAGER_INGRESS_GATEWAY_SERVICE_NAME", "aks-istio-ingressgateway-external"),
    "istio_internal_ingress_gateway_min_replicas": as_int("ISTIO_INTERNAL_INGRESS_GATEWAY_MIN_REPLICAS", 2),
    "istio_internal_ingress_gateway_max_replicas": as_int("ISTIO_INTERNAL_INGRESS_GATEWAY_MAX_REPLICAS", 5),
    "istio_external_ingress_gateway_min_replicas": as_int("ISTIO_EXTERNAL_INGRESS_GATEWAY_MIN_REPLICAS", 2),
    "istio_external_ingress_gateway_max_replicas": as_int("ISTIO_EXTERNAL_INGRESS_GATEWAY_MAX_REPLICAS", 5),
    "istio_kiali_enabled": as_bool("ISTIO_KIALI_ENABLED", True),
    "istio_kiali_namespace": get("ISTIO_KIALI_NAMESPACE", "aks-istio-system"),
    "istio_kiali_replicas": as_int("ISTIO_KIALI_REPLICAS", 1),
    "istio_kiali_view_only_mode": as_bool("ISTIO_KIALI_VIEW_ONLY_MODE", True),
    "istio_kiali_operator_chart_version": get("ISTIO_KIALI_OPERATOR_CHART_VERSION", "2.20.0"),
    "istio_kiali_prometheus_retention_period": get("ISTIO_KIALI_PROMETHEUS_RETENTION_PERIOD", "30d"),
    "istio_kiali_prometheus_scrape_interval": get("ISTIO_KIALI_PROMETHEUS_SCRAPE_INTERVAL", "30s"),
    "istio_kiali_proxy_identity_name": get("ISTIO_KIALI_PROXY_IDENTITY_NAME", "id-aks-istio-kiali-proxy"),
    "istio_kiali_proxy_service_account_name": get("ISTIO_KIALI_PROXY_SERVICE_ACCOUNT_NAME", "azuremonitor-query"),
    "istio_kiali_proxy_service_name": get("ISTIO_KIALI_PROXY_SERVICE_NAME", "azuremonitor-query"),
    "grafana_admin_principal_ids": csv_list("GRAFANA_ADMIN_PRINCIPAL_IDS"),
    "prometheus_rule_group_enabled": as_bool("PROMETHEUS_RULE_GROUP_ENABLED", True),
    "prometheus_rule_group_interval": get("PROMETHEUS_RULE_GROUP_INTERVAL", "PT1M"),
    "service_monitor_crd_enabled": as_bool("SERVICE_MONITOR_CRD_ENABLED", True),
    "keda_prometheus_auth_name": get("KEDA_PROMETHEUS_AUTH_NAME", "azure-managed-prometheus"),
    "keda_prometheus_identity_name": get("KEDA_PROMETHEUS_IDENTITY_NAME", "id-keda-prometheus"),
    "keda_prometheus_operator_namespace": get("KEDA_PROMETHEUS_OPERATOR_NAMESPACE", "kube-system"),
    "keda_prometheus_operator_service_account_name": get("KEDA_PROMETHEUS_OPERATOR_SERVICE_ACCOUNT_NAME", "keda-operator"),
    "keda_prometheus_operator_deployment_name": get("KEDA_PROMETHEUS_OPERATOR_DEPLOYMENT_NAME", "keda-operator"),
    "keda_prometheus_federated_credential_name": get("KEDA_PROMETHEUS_FEDERATED_CREDENTIAL_NAME", ""),
    "karpenter_namespace": get("KARPENTER_NAMESPACE", "kube-system"),
    "karpenter_service_account": get("KARPENTER_SERVICE_ACCOUNT", "karpenter-sa"),
    "karpenter_identity_name": get("KARPENTER_IDENTITY_NAME", "id-karpenter-gpu"),
    "karpenter_image_repository": get("KARPENTER_IMAGE_REPO", "quay.io/hydracz/karpenter-controller"),
    "karpenter_image_tag": get("KARPENTER_IMAGE_TAG", "v20260323-dev"),
    "gpu_sku_name": get("GPU_SKU_NAME", "Standard_NC128lds_xl_RTXPRO6000BSE_v6"),
    "gpu_type": get("GPU_TYPE", "rtxpro6000-bse"),
    "gpu_node_workload_label": get("GPU_NODE_WORKLOAD_LABEL", "gpu-test"),
    "gpu_zones": csv_list("GPU_ZONES"),
    "gpu_node_image_family": get("GPU_NODE_IMAGE_FAMILY", "Ubuntu2404"),
    "gpu_os_disk_size_gb": as_int("GPU_OS_DISK_SIZE_GB", 1024),
    "install_gpu_drivers": as_bool("INSTALL_GPU_DRIVERS", False),
    "consolidate_after": get("CONSOLIDATE_AFTER", "10m"),
    "spot_max_price": get("SPOT_MAX_PRICE", "-1"),
    "gpu_operator_enabled": as_bool("GPU_OPERATOR_ENABLED", True),
    "gpu_operator_namespace": get("GPU_OPERATOR_NAMESPACE", "gpu-operator"),
    "gpu_driver_cr_name": get("GPU_DRIVER_CR_NAME", "rtxpro6000-azure"),
    "gpu_driver_node_selector_key": get("GPU_DRIVER_NODE_SELECTOR_KEY", "karpenter.azure.com/sku-gpu-name"),
    "gpu_driver_node_selector_value": get("GPU_DRIVER_NODE_SELECTOR_VALUE", ""),
    "gpu_driver_source_repository": get("GPU_DRIVER_SOURCE_REPOSITORY", "docker.io/yingeli"),
    "gpu_driver_image": get("GPU_DRIVER_IMAGE", "driver"),
    "gpu_driver_version": get("GPU_DRIVER_VERSION", "580.105.08"),
    "gpu_driver_require_matching_nodes": as_bool("GPU_DRIVER_REQUIRE_MATCHING_NODES", False),
    "gpu_driver_sync_enabled": as_bool("GPU_DRIVER_SYNC_ENABLED", True),
    "gpu_driver_sync_use_sudo": as_bool("GPU_DRIVER_SYNC_USE_SUDO", False),
    "gpu_driver_allow_os_tag_alias": as_bool("GPU_DRIVER_ALLOW_OS_TAG_ALIAS", False),
    "gpu_driver_version_source_tag_2204": get("GPU_DRIVER_VERSION_SOURCE_TAG_2204", "580.105.08-ubuntu22.04"),
    "gpu_driver_version_source_tag_2404": get("GPU_DRIVER_VERSION_SOURCE_TAG_2404", "580.105.08-ubuntu24.04"),
    "tags": tags,
}

output_path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY

echo "Rendered Terraform variables to ${OUTPUT_FILE}"