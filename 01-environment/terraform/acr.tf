data "azurerm_container_registry" "existing" {
  count = local.create_acr ? 0 : 1

  name                = local.existing_acr_name
  resource_group_name = local.existing_acr_resource_group
}

resource "azurerm_container_registry" "main" {
  count = local.create_acr ? 1 : 0

  name                = var.acr_name
  resource_group_name = azurerm_resource_group.main.name
  location            = var.location
  sku                 = "Standard"
  admin_enabled       = false
  tags                = local.common_tags
}