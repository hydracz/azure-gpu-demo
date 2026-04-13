resource "azurerm_resource_group" "main" {
  name     = var.resource_group_name
  location = var.location
  tags     = local.common_tags
}

resource "azurerm_resource_group" "network" {
  count    = local.create_network ? 1 : 0
  name     = local.network_resource_group_name
  location = var.location
  tags     = local.common_tags
}