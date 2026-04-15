data "azurerm_container_registry" "existing" {
  name                = local.existing_acr_name
  resource_group_name = local.existing_acr_resource_group
}