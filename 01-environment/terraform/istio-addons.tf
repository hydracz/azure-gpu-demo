resource "azurerm_user_assigned_identity" "istio_kiali_proxy" {
  count = var.istio_kiali_enabled ? 1 : 0

  name                = var.istio_kiali_proxy_identity_name
  resource_group_name = azurerm_resource_group.main.name
  location            = var.location
  tags                = local.common_tags
}

resource "azurerm_role_assignment" "istio_kiali_proxy_monitoring_data_reader" {
  count = var.istio_kiali_enabled ? 1 : 0

  scope                = azurerm_monitor_workspace.main.id
  role_definition_name = "Monitoring Data Reader"
  principal_id         = azurerm_user_assigned_identity.istio_kiali_proxy[0].principal_id
}

resource "azurerm_federated_identity_credential" "istio_kiali_proxy" {
  count = var.istio_kiali_enabled ? 1 : 0

  name                      = "${var.istio_kiali_proxy_identity_name}-fed-cred"
  audience                  = ["api://AzureADTokenExchange"]
  issuer                    = azurerm_kubernetes_cluster.main.oidc_issuer_url
  user_assigned_identity_id = azurerm_user_assigned_identity.istio_kiali_proxy[0].id
  subject                   = "system:serviceaccount:${var.istio_kiali_namespace}:${var.istio_kiali_proxy_service_account_name}"
}

resource "null_resource" "install_istio_addons" {
  count = var.istio_service_mesh_enabled ? 1 : 0

  triggers = {
    cluster_id                                  = azurerm_kubernetes_cluster.main.id
    kubeconfig_path                             = local_file.aks_kubeconfig.filename
    subscription_id                             = var.subscription_id
    resource_group_name                         = azurerm_resource_group.main.name
    cluster_name                                = azurerm_kubernetes_cluster.main.name
    monitor_workspace_query_endpoint            = azurerm_monitor_workspace.main.query_endpoint
    istio_internal_ingress_gateway_enabled      = tostring(var.istio_internal_ingress_gateway_enabled)
    istio_external_ingress_gateway_enabled      = tostring(var.istio_external_ingress_gateway_enabled)
    istio_internal_ingress_gateway_min_replicas = tostring(var.istio_internal_ingress_gateway_min_replicas)
    istio_internal_ingress_gateway_max_replicas = tostring(var.istio_internal_ingress_gateway_max_replicas)
    istio_external_ingress_gateway_min_replicas = tostring(var.istio_external_ingress_gateway_min_replicas)
    istio_external_ingress_gateway_max_replicas = tostring(var.istio_external_ingress_gateway_max_replicas)
    istio_kiali_enabled                         = tostring(var.istio_kiali_enabled)
    istio_kiali_namespace                       = var.istio_kiali_namespace
    istio_kiali_replicas                        = tostring(var.istio_kiali_replicas)
    istio_kiali_view_only_mode                  = tostring(var.istio_kiali_view_only_mode)
    istio_kiali_operator_chart_version          = var.istio_kiali_operator_chart_version
    istio_kiali_prometheus_retention_period     = var.istio_kiali_prometheus_retention_period
    istio_kiali_prometheus_scrape_interval      = var.istio_kiali_prometheus_scrape_interval
    istio_kiali_proxy_service_name              = var.istio_kiali_proxy_service_name
    istio_kiali_proxy_service_account_name      = var.istio_kiali_proxy_service_account_name
    istio_kiali_proxy_client_id                 = var.istio_kiali_enabled ? azurerm_user_assigned_identity.istio_kiali_proxy[0].client_id : ""
    install_script_sha                          = filesha256("${path.module}/scripts/install-istio-addons.sh")
    uninstall_script_sha                        = filesha256("${path.module}/scripts/uninstall-istio-addons.sh")
    helper_script_sha                           = filesha256("${path.module}/scripts/common.sh")
  }

  provisioner "local-exec" {
    command     = "bash ${path.module}/scripts/install-istio-addons.sh"
    interpreter = ["/bin/bash", "-lc"]

    environment = {
      KUBECONFIG_FILE                             = self.triggers.kubeconfig_path
      AZURE_SUBSCRIPTION_ID                       = self.triggers.subscription_id
      RESOURCE_GROUP                              = self.triggers.resource_group_name
      CLUSTER_NAME                                = self.triggers.cluster_name
      MONITOR_WORKSPACE_QUERY_ENDPOINT            = self.triggers.monitor_workspace_query_endpoint
      ISTIO_INTERNAL_INGRESS_GATEWAY_ENABLED      = self.triggers.istio_internal_ingress_gateway_enabled
      ISTIO_EXTERNAL_INGRESS_GATEWAY_ENABLED      = self.triggers.istio_external_ingress_gateway_enabled
      ISTIO_INTERNAL_INGRESS_GATEWAY_MIN_REPLICAS = self.triggers.istio_internal_ingress_gateway_min_replicas
      ISTIO_INTERNAL_INGRESS_GATEWAY_MAX_REPLICAS = self.triggers.istio_internal_ingress_gateway_max_replicas
      ISTIO_EXTERNAL_INGRESS_GATEWAY_MIN_REPLICAS = self.triggers.istio_external_ingress_gateway_min_replicas
      ISTIO_EXTERNAL_INGRESS_GATEWAY_MAX_REPLICAS = self.triggers.istio_external_ingress_gateway_max_replicas
      ISTIO_KIALI_ENABLED                         = self.triggers.istio_kiali_enabled
      ISTIO_KIALI_NAMESPACE                       = self.triggers.istio_kiali_namespace
      ISTIO_KIALI_REPLICAS                        = self.triggers.istio_kiali_replicas
      ISTIO_KIALI_VIEW_ONLY_MODE                  = self.triggers.istio_kiali_view_only_mode
      ISTIO_KIALI_OPERATOR_CHART_VERSION          = self.triggers.istio_kiali_operator_chart_version
      ISTIO_KIALI_PROMETHEUS_RETENTION_PERIOD     = self.triggers.istio_kiali_prometheus_retention_period
      ISTIO_KIALI_PROMETHEUS_SCRAPE_INTERVAL      = self.triggers.istio_kiali_prometheus_scrape_interval
      ISTIO_KIALI_PROXY_SERVICE_NAME              = self.triggers.istio_kiali_proxy_service_name
      ISTIO_KIALI_PROXY_SERVICE_ACCOUNT_NAME      = self.triggers.istio_kiali_proxy_service_account_name
      ISTIO_KIALI_PROXY_CLIENT_ID                 = self.triggers.istio_kiali_proxy_client_id
    }
  }

  provisioner "local-exec" {
    when        = destroy
    on_failure  = continue
    command     = "bash ${path.module}/scripts/uninstall-istio-addons.sh"
    interpreter = ["/bin/bash", "-lc"]

    environment = {
      KUBECONFIG_FILE                        = self.triggers.kubeconfig_path
      AZURE_SUBSCRIPTION_ID                  = self.triggers.subscription_id
      RESOURCE_GROUP                         = self.triggers.resource_group_name
      CLUSTER_NAME                           = self.triggers.cluster_name
      ISTIO_KIALI_NAMESPACE                  = self.triggers.istio_kiali_namespace
      ISTIO_KIALI_ENABLED                    = self.triggers.istio_kiali_enabled
      ISTIO_KIALI_PROXY_SERVICE_NAME         = self.triggers.istio_kiali_proxy_service_name
      ISTIO_KIALI_PROXY_SERVICE_ACCOUNT_NAME = self.triggers.istio_kiali_proxy_service_account_name
    }
  }

  depends_on = [
    time_sleep.aks_api_ready,
    null_resource.ama_metrics_config,
    azurerm_role_assignment.istio_kiali_proxy_monitoring_data_reader,
    azurerm_federated_identity_credential.istio_kiali_proxy,
  ]
}