locals {
  aks_subnet_id               = var.existing_subnet_id
  aks_vnet_id                 = split("/subnets/", local.aks_subnet_id)[0]
  aks_subnet_id_parts         = split("/", trimspace(local.aks_subnet_id))
  network_resource_group_name = trimspace(local.aks_subnet_id) == "" ? null : local.aks_subnet_id_parts[4]
  existing_acr_id_parts       = split("/", trimspace(var.existing_acr_id))
  existing_acr_resource_group = local.existing_acr_id_parts[4]
  existing_acr_name           = local.existing_acr_id_parts[8]
  acr_id                      = data.azurerm_container_registry.existing.id
  acr_name                    = data.azurerm_container_registry.existing.name
  acr_login_server            = data.azurerm_container_registry.existing.login_server
  aks_endpoint                = "https://${azurerm_kubernetes_cluster.main.fqdn}"
  kubeconfig_path             = "${path.module}/.generated-kubeconfig"
  shared_env_file             = abspath("${path.module}/../../.generated.env")

  gpu_zones = length(var.gpu_zones) > 0 ? var.gpu_zones : ["${var.location}-1"]

  gpu_driver_node_selector_value_parts      = split("_", var.gpu_sku_name)
  gpu_driver_node_selector_value            = trimspace(var.gpu_driver_node_selector_value) != "" ? var.gpu_driver_node_selector_value : local.gpu_driver_node_selector_value_parts[length(local.gpu_driver_node_selector_value_parts) - 2]
  gpu_driver_version_source_tag_2204        = trimspace(var.gpu_driver_version_source_tag_2204) != "" ? var.gpu_driver_version_source_tag_2204 : "${var.gpu_driver_version}-ubuntu22.04"
  gpu_driver_version_source_tag_2404        = trimspace(var.gpu_driver_version_source_tag_2404) != "" ? var.gpu_driver_version_source_tag_2404 : "${var.gpu_driver_version}-ubuntu24.04"
  keda_prometheus_federated_credential_name = trimspace(var.keda_prometheus_federated_credential_name) != "" ? var.keda_prometheus_federated_credential_name : "${var.keda_prometheus_identity_name}-keda-operator"

  karpenter_chart_dir          = "${path.module}/../charts/karpenter"
  karpenter_crd_chart_dir      = "${path.module}/../charts/karpenter-crd"
  gpu_operator_chart_dir       = "${path.module}/../charts/gpu-operator"
  cert_manager_manifest        = "${path.module}/../charts/cert-manager.yaml"
  cert_manager_issuer_template = "${path.module}/../charts/letencrypt-signer.yaml"
  grafana_dashboard_dir        = "${path.module}/../grafana/dashboards"
  service_monitor_crd          = "${path.module}/../charts/crd-servicemonitors.yaml"
  ama_metrics_config           = "${path.module}/../charts/ama-metrics-settings-configmap.yaml"

  karpenter_chart_hash = sha256(join("", [
    for file in sort(fileset(local.karpenter_chart_dir, "**")) : filesha256("${local.karpenter_chart_dir}/${file}")
  ]))
  karpenter_crd_chart_hash = sha256(join("", [
    for file in sort(fileset(local.karpenter_crd_chart_dir, "**")) : filesha256("${local.karpenter_crd_chart_dir}/${file}")
  ]))
  gpu_operator_chart_hash = sha256(join("", [
    for file in sort(fileset(local.gpu_operator_chart_dir, "**")) : filesha256("${local.gpu_operator_chart_dir}/${file}")
  ]))
  cert_manager_manifest_hash        = filesha256(local.cert_manager_manifest)
  cert_manager_issuer_template_hash = filesha256(local.cert_manager_issuer_template)
  grafana_dashboard_hash = sha256(join("", [
    for file in sort(fileset(local.grafana_dashboard_dir, "*.json")) : filesha256("${local.grafana_dashboard_dir}/${file}")
  ]))
  service_monitor_crd_hash = filesha256(local.service_monitor_crd)
  ama_metrics_config_hash  = filesha256(local.ama_metrics_config)

  common_tags = merge(
    {
      workload = "azure-gpu-demo"
      stage    = "01-environment"
      managed  = "terraform"
    },
    var.tags,
  )
}