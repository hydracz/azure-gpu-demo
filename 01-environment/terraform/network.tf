resource "azurerm_virtual_network" "main" {
  count               = local.create_network ? 1 : 0
  name                = local.vnet_name
  location            = var.location
  resource_group_name = azurerm_resource_group.network[0].name
  address_space       = var.vnet_address_space
  tags                = local.common_tags
}

resource "azurerm_subnet" "aks" {
  count                = local.create_network ? 1 : 0
  name                 = var.aks_subnet_name
  resource_group_name  = azurerm_resource_group.network[0].name
  virtual_network_name = azurerm_virtual_network.main[0].name
  address_prefixes     = var.aks_subnet_address_prefixes

  service_endpoints = [
    "Microsoft.ContainerRegistry",
    "Microsoft.Storage",
  ]
}