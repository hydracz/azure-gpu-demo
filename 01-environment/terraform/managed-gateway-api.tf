resource "null_resource" "register_managed_gateway_api_prereqs" {
  count = var.managed_gateway_api_enabled ? 1 : 0

  triggers = {
    subscription_id             = var.subscription_id
    managed_gateway_api_enabled = tostring(var.managed_gateway_api_enabled)
    register_script_sha         = filesha256("${path.module}/../scripts/ensure-managed-gateway-api.sh")
  }

  provisioner "local-exec" {
    command     = "bash ${path.module}/../scripts/ensure-managed-gateway-api.sh"
    interpreter = ["/bin/bash", "-lc"]

    environment = {
      KUBECONFIG_FILE                 = local.kubeconfig_path
      AZURE_SUBSCRIPTION_ID           = self.triggers.subscription_id
      RESOURCE_GROUP                  = azurerm_resource_group.main.name
      CLUSTER_NAME                    = azurerm_kubernetes_cluster.main.name
      AKS_MANAGED_GATEWAY_API_ENABLED = self.triggers.managed_gateway_api_enabled
      MANAGED_GATEWAY_API_ACTION      = "register"
    }
  }
}

resource "azapi_update_resource" "enable_managed_gateway_api" {
  count       = var.managed_gateway_api_enabled ? 1 : 0
  type        = "Microsoft.ContainerService/managedClusters@2026-01-02-preview"
  resource_id = azurerm_kubernetes_cluster.main.id

  body = {
    properties = {
      ingressProfile = {
        gatewayApi = {
          installation = "Standard"
        }
      }
    }
  }

  ignore_missing_property = true

  depends_on = [
    time_sleep.aks_api_ready,
    null_resource.register_managed_gateway_api_prereqs,
  ]
}

resource "null_resource" "wait_for_managed_gateway_api" {
  count = var.managed_gateway_api_enabled ? 1 : 0

  triggers = {
    cluster_id                  = azurerm_kubernetes_cluster.main.id
    kubeconfig_path             = local.kubeconfig_path
    subscription_id             = var.subscription_id
    resource_group_name         = azurerm_resource_group.main.name
    cluster_name                = azurerm_kubernetes_cluster.main.name
    managed_gateway_api_enabled = tostring(var.managed_gateway_api_enabled)
    istio_service_mesh_enabled  = tostring(var.istio_service_mesh_enabled)
    azapi_resource_id           = azapi_update_resource.enable_managed_gateway_api[0].id
    wait_script_sha             = filesha256("${path.module}/../scripts/ensure-managed-gateway-api.sh")
  }

  provisioner "local-exec" {
    command     = "bash ${path.module}/../scripts/ensure-managed-gateway-api.sh"
    interpreter = ["/bin/bash", "-lc"]

    environment = {
      KUBECONFIG_FILE                 = self.triggers.kubeconfig_path
      AZURE_SUBSCRIPTION_ID           = self.triggers.subscription_id
      RESOURCE_GROUP                  = self.triggers.resource_group_name
      CLUSTER_NAME                    = self.triggers.cluster_name
      AKS_MANAGED_GATEWAY_API_ENABLED = self.triggers.managed_gateway_api_enabled
      ISTIO_SERVICE_MESH_ENABLED      = self.triggers.istio_service_mesh_enabled
      MANAGED_GATEWAY_API_ACTION      = "wait"
    }
  }

  depends_on = [
    azapi_update_resource.enable_managed_gateway_api,
  ]
}