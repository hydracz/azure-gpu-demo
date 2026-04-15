resource "azurerm_monitor_workspace" "main" {
  name                          = var.monitor_workspace_name
  resource_group_name           = azurerm_resource_group.main.name
  location                      = var.location
  public_network_access_enabled = var.monitor_workspace_public_network_access_enabled
  tags                          = local.common_tags
}

resource "azurerm_log_analytics_workspace" "main" {
  name                = var.log_analytics_workspace_name
  resource_group_name = azurerm_resource_group.main.name
  location            = var.location
  sku                 = "PerGB2018"
  retention_in_days   = 30
  tags                = local.common_tags
}

resource "azurerm_dashboard_grafana" "main" {
  name                              = var.grafana_name
  resource_group_name               = azurerm_resource_group.main.name
  location                          = var.location
  grafana_major_version             = var.grafana_major_version
  api_key_enabled                   = false
  deterministic_outbound_ip_enabled = false
  public_network_access_enabled     = var.grafana_public_network_access_enabled
  zone_redundancy_enabled           = false
  tags                              = local.common_tags

  identity {
    type = "SystemAssigned"
  }

  azure_monitor_workspace_integrations {
    resource_id = azurerm_monitor_workspace.main.id
  }
}

resource "azurerm_role_assignment" "grafana_admin" {
  for_each             = toset(var.grafana_admin_principal_ids)
  scope                = azurerm_dashboard_grafana.main.id
  role_definition_name = "Grafana Admin"
  principal_id         = each.value
}

resource "azurerm_role_assignment" "grafana_monitoring_data_reader" {
  scope                = azurerm_monitor_workspace.main.id
  role_definition_name = "Monitoring Data Reader"
  principal_id         = azurerm_dashboard_grafana.main.identity[0].principal_id
}

resource "azurerm_role_assignment" "grafana_monitoring_metrics_publisher" {
  scope                = azurerm_monitor_workspace.main.id
  role_definition_name = "Monitoring Metrics Publisher"
  principal_id         = azurerm_dashboard_grafana.main.identity[0].principal_id
}

resource "null_resource" "import_grafana_dashboards" {
  count = var.grafana_dashboard_import_enabled ? 1 : 0

  triggers = {
    subscription_id      = var.subscription_id
    resource_group_name  = azurerm_resource_group.main.name
    grafana_name         = azurerm_dashboard_grafana.main.name
    dashboard_bundle_sha = local.grafana_dashboard_hash
    import_script_sha    = filesha256("${path.module}/../scripts/import-grafana-dashboards.sh")
  }

  provisioner "local-exec" {
    command     = "bash ${path.module}/../scripts/import-grafana-dashboards.sh"
    interpreter = ["/bin/bash", "-lc"]

    environment = {
      AZURE_SUBSCRIPTION_ID = self.triggers.subscription_id
      RESOURCE_GROUP        = self.triggers.resource_group_name
      GRAFANA_NAME          = self.triggers.grafana_name
    }
  }

  depends_on = [
    azurerm_dashboard_grafana.main,
    azurerm_role_assignment.grafana_monitoring_data_reader,
    azurerm_role_assignment.grafana_monitoring_metrics_publisher,
  ]
}