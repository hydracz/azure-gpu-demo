#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TERRAFORM_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../../../common.sh"

cd "${TERRAFORM_DIR}"

export TERRAFORM_DIR

terraform output -json | python3 -c '
import json
import os
import sys

outputs = json.load(sys.stdin)
terraform_dir = os.environ["TERRAFORM_DIR"]

mapping = {
    "subscription_id": ["AZ_SUBSCRIPTION_ID"],
    "location": ["LOCATION"],
    "resource_group_name": ["RESOURCE_GROUP"],
    "network_resource_group_name": ["NETWORK_RESOURCE_GROUP"],
    "cluster_name": ["CLUSTER_NAME"],
    "aks_subnet_id": ["AKS_SUBNET_ID", "EXISTING_VNET_SUBNET_ID"],
    "cluster_id": ["CLUSTER_ID"],
    "cluster_fqdn": ["CLUSTER_FQDN"],
    "cluster_endpoint": ["CLUSTER_ENDPOINT", "AKS_ENDPOINT"],
    "service_mesh_mode": ["SERVICE_MESH_MODE"],
    "service_mesh_revisions": ["SERVICE_MESH_REVISIONS_CSV"],
    "monitor_workspace_query_endpoint": ["MONITOR_WORKSPACE_QUERY_ENDPOINT"],
    "cert_manager_ingress_class_name": ["CERT_MANAGER_INGRESS_CLASS_NAME"],
    "cert_manager_staging_issuer_name": ["CERT_MANAGER_STAGING_ISSUER_NAME"],
    "cert_manager_prod_issuer_name": ["CERT_MANAGER_PROD_ISSUER_NAME", "QWEN_LOADTEST_CERT_ISSUER_NAME"],
    "keda_prometheus_auth_name": ["KEDA_PROMETHEUS_AUTH_NAME", "QWEN_LOADTEST_KEDA_AUTH_NAME"],
    "keda_prometheus_identity_name": ["KEDA_PROMETHEUS_IDENTITY_NAME"],
    "istio_kiali_namespace": ["ISTIO_KIALI_NAMESPACE"],
    "istio_kiali_proxy_client_id": ["ISTIO_KIALI_PROXY_CLIENT_ID"],
    "oidc_issuer_url": ["OIDC_ISSUER_URL", "AKS_OIDC_ISSUER"],
    "node_resource_group": ["NODE_RESOURCE_GROUP", "AZURE_NODE_RESOURCE_GROUP"],
    "acr_name": ["ACR_NAME"],
    "acr_id": ["ACR_ID", "EXISTING_ACR_ID"],
    "acr_login_server": ["ACR_LOGIN_SERVER"],
    "monitor_workspace_id": ["MONITOR_WORKSPACE_ID"],
    "log_analytics_workspace_id": ["LOG_ANALYTICS_WORKSPACE_ID"],
    "grafana_id": ["GRAFANA_ID"],
    "kubeconfig_path": ["AKS_KUBECONFIG_FILE"],
    "karpenter_identity_client_id": ["KARPENTER_CLIENT_ID", "KARPENTER_IDENTITY_CLIENT_ID"],
    "karpenter_identity_id": ["KARPENTER_IDENTITY_ID"],
    "gpu_driver_selector": ["GPU_DRIVER_SELECTOR"],
    "kubectl_credentials_command": ["KUBECTL_CREDENTIALS_COMMAND"],
}

def normalize(value):
    if value is None:
        return None
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, list):
        return ",".join(str(item) for item in value)
    return str(value)

for output_name, env_names in mapping.items():
    if output_name not in outputs:
        continue
    value = normalize(outputs[output_name].get("value"))
    if value in (None, "", "null"):
        continue
    if output_name == "kubeconfig_path" and not os.path.isabs(value):
        value = os.path.abspath(os.path.join(terraform_dir, value))
    for env_name in env_names:
        print(f"{env_name}\t{value}")
' | while IFS=$'\t' read -r key value; do
  write_generated_env "${key}" "${value}"
done