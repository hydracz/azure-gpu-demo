resource "tls_private_key" "aks_admin" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "azurerm_user_assigned_identity" "aks_control_plane" {
  name                = var.aks_identity_name
  location            = var.location
  resource_group_name = azurerm_resource_group.main.name
  tags                = local.common_tags
}

resource "azurerm_role_assignment" "aks_control_plane_vnet_reader" {
  scope                            = local.aks_vnet_id
  role_definition_name             = "Reader"
  principal_id                     = azurerm_user_assigned_identity.aks_control_plane.principal_id
  skip_service_principal_aad_check = true
}

resource "azurerm_role_assignment" "aks_control_plane_subnet_network_contributor" {
  scope                            = local.aks_subnet_id
  role_definition_name             = "Network Contributor"
  principal_id                     = azurerm_user_assigned_identity.aks_control_plane.principal_id
  skip_service_principal_aad_check = true
}

resource "azurerm_kubernetes_cluster" "main" {
  name                = var.cluster_name
  location            = var.location
  resource_group_name = azurerm_resource_group.main.name
  dns_prefix          = var.cluster_name
  tags                = local.common_tags

  oidc_issuer_enabled       = true
  workload_identity_enabled = true

  default_node_pool {
    name                        = var.system_pool_name
    node_count                  = var.system_node_count
    vm_size                     = var.system_vm_size
    temporary_name_for_rotation = "systemtmp"
    vnet_subnet_id              = local.aks_subnet_id

    upgrade_settings {
      max_surge = "10%"
    }
  }

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.aks_control_plane.id]
  }

  linux_profile {
    admin_username = var.aks_admin_username

    ssh_key {
      key_data = tls_private_key.aks_admin.public_key_openssh
    }
  }

  monitor_metrics {
    annotations_allowed = null
    labels_allowed      = null
  }

  network_profile {
    network_plugin      = "azure"
    network_plugin_mode = "overlay"
    network_policy      = "cilium"
    network_data_plane  = "cilium"
    load_balancer_sku   = "standard"
    service_cidr        = var.service_cidr
    dns_service_ip      = var.dns_service_ip
  }

  workload_autoscaler_profile {
    keda_enabled = true
  }

  dynamic "service_mesh_profile" {
    for_each = var.istio_service_mesh_enabled ? [1] : []

    content {
      mode                             = "Istio"
      revisions                        = var.istio_revisions
      internal_ingress_gateway_enabled = var.istio_internal_ingress_gateway_enabled
      external_ingress_gateway_enabled = var.istio_external_ingress_gateway_enabled
    }
  }

  storage_profile {
    blob_driver_enabled         = var.blob_driver_enabled
    disk_driver_enabled         = true
    file_driver_enabled         = true
    snapshot_controller_enabled = true
  }

  depends_on = [
    null_resource.prepare_shared_assets,
    azurerm_dashboard_grafana.main,
    azurerm_log_analytics_workspace.main,
    azurerm_monitor_workspace.main,
    azurerm_role_assignment.aks_control_plane_vnet_reader,
    azurerm_role_assignment.aks_control_plane_subnet_network_contributor,
  ]
}

resource "azurerm_role_assignment" "aks_acr_pull" {
  scope                = local.acr_id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_kubernetes_cluster.main.kubelet_identity[0].object_id
}

data "azurerm_monitor_diagnostic_categories" "aks" {
  resource_id = azurerm_kubernetes_cluster.main.id
}

resource "azurerm_monitor_diagnostic_setting" "aks" {
  name                       = var.diagnostic_setting_name
  target_resource_id         = azurerm_kubernetes_cluster.main.id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.main.id

  dynamic "enabled_log" {
    for_each = toset(data.azurerm_monitor_diagnostic_categories.aks.log_category_types)

    content {
      category = enabled_log.value
    }
  }

  dynamic "enabled_metric" {
    for_each = toset(data.azurerm_monitor_diagnostic_categories.aks.metrics)

    content {
      category = enabled_metric.value
    }
  }
}