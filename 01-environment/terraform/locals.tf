locals {
  create_network = trimspace(var.existing_subnet_id) == ""

  network_resource_group_name = var.network_resource_group_name != "" ? var.network_resource_group_name : "${var.resource_group_name}-network"
  vnet_name                   = var.vnet_name != "" ? var.vnet_name : "vnet-${var.cluster_name}"
  aks_subnet_id               = local.create_network ? azurerm_subnet.aks[0].id : var.existing_subnet_id
  aks_vnet_id                 = split("/subnets/", local.aks_subnet_id)[0]
  aks_endpoint                = "https://${azurerm_kubernetes_cluster.main.fqdn}"
  kubeconfig_path             = "${path.module}/.generated-kubeconfig"

  gpu_zones = length(var.gpu_zones) > 0 ? var.gpu_zones : ["${var.location}-1"]

  gpu_driver_node_selector_value_parts = split("_", var.gpu_sku_name)
  gpu_driver_node_selector_value       = trimspace(var.gpu_driver_node_selector_value) != "" ? var.gpu_driver_node_selector_value : local.gpu_driver_node_selector_value_parts[length(local.gpu_driver_node_selector_value_parts) - 2]
  gpu_driver_version_source_tag_2204   = trimspace(var.gpu_driver_version_source_tag_2204) != "" ? var.gpu_driver_version_source_tag_2204 : "${var.gpu_driver_version}-ubuntu22.04"
  gpu_driver_version_source_tag_2404   = trimspace(var.gpu_driver_version_source_tag_2404) != "" ? var.gpu_driver_version_source_tag_2404 : "${var.gpu_driver_version}-ubuntu24.04"

  karpenter_chart_dir     = "${path.module}/../charts/karpenter"
  karpenter_crd_chart_dir = "${path.module}/../charts/karpenter-crd"
  gpu_operator_chart_dir  = "${path.module}/../charts/gpu-operator"
  service_monitor_crd     = "${path.module}/../charts/crd-servicemonitors.yaml"

  karpenter_chart_hash = sha256(join("", [
    for file in sort(fileset(local.karpenter_chart_dir, "**")) : filesha256("${local.karpenter_chart_dir}/${file}")
  ]))
  karpenter_crd_chart_hash = sha256(join("", [
    for file in sort(fileset(local.karpenter_crd_chart_dir, "**")) : filesha256("${local.karpenter_crd_chart_dir}/${file}")
  ]))
  gpu_operator_chart_hash = sha256(join("", [
    for file in sort(fileset(local.gpu_operator_chart_dir, "**")) : filesha256("${local.gpu_operator_chart_dir}/${file}")
  ]))
  service_monitor_crd_hash = filesha256(local.service_monitor_crd)

  common_tags = merge(
    {
      workload = "azure-gpu-demo"
      stage    = "01-environment"
      managed  = "terraform"
    },
    var.tags,
  )
}