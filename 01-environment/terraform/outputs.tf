output "resource_group_name" {
  value = azurerm_resource_group.main.name
}

output "network_resource_group_name" {
  value = local.create_network ? azurerm_resource_group.network[0].name : null
}

output "aks_subnet_id" {
  value = local.aks_subnet_id
}

output "cluster_id" {
  value = azurerm_kubernetes_cluster.main.id
}

output "cluster_fqdn" {
  value = azurerm_kubernetes_cluster.main.fqdn
}

output "cluster_endpoint" {
  value = local.aks_endpoint
}

output "service_mesh_mode" {
  value = try(azurerm_kubernetes_cluster.main.service_mesh_profile[0].mode, null)
}

output "service_mesh_revisions" {
  value = try(azurerm_kubernetes_cluster.main.service_mesh_profile[0].revisions, [])
}

output "oidc_issuer_url" {
  value = azurerm_kubernetes_cluster.main.oidc_issuer_url
}

output "node_resource_group" {
  value = azurerm_kubernetes_cluster.main.node_resource_group
}

output "acr_id" {
  value = azurerm_container_registry.main.id
}

output "acr_login_server" {
  value = azurerm_container_registry.main.login_server
}

output "monitor_workspace_id" {
  value = azurerm_monitor_workspace.main.id
}

output "log_analytics_workspace_id" {
  value = azurerm_log_analytics_workspace.main.id
}

output "grafana_id" {
  value = azurerm_dashboard_grafana.main.id
}

output "kubeconfig_path" {
  value = local_file.aks_kubeconfig.filename
}

output "karpenter_identity_client_id" {
  value = azurerm_user_assigned_identity.karpenter.client_id
}

output "karpenter_identity_id" {
  value = azurerm_user_assigned_identity.karpenter.id
}

output "gpu_driver_selector" {
  value = "${var.gpu_driver_node_selector_key}=${local.gpu_driver_node_selector_value}"
}

output "kubectl_credentials_command" {
  value = "az aks get-credentials --resource-group ${azurerm_resource_group.main.name} --name ${azurerm_kubernetes_cluster.main.name} --overwrite-existing"
}