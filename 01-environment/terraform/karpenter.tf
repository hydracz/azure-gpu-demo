resource "azurerm_user_assigned_identity" "karpenter" {
  name                = var.karpenter_identity_name
  resource_group_name = azurerm_resource_group.main.name
  location            = var.location
  tags                = local.common_tags
}

resource "azurerm_role_assignment" "karpenter_node_rg_vm_contributor" {
  scope                            = "/subscriptions/${var.subscription_id}/resourceGroups/${azurerm_kubernetes_cluster.main.node_resource_group}"
  role_definition_name             = "Virtual Machine Contributor"
  principal_id                     = azurerm_user_assigned_identity.karpenter.principal_id
  skip_service_principal_aad_check = true
}

resource "azurerm_role_assignment" "karpenter_node_rg_network_contributor" {
  scope                            = "/subscriptions/${var.subscription_id}/resourceGroups/${azurerm_kubernetes_cluster.main.node_resource_group}"
  role_definition_name             = "Network Contributor"
  principal_id                     = azurerm_user_assigned_identity.karpenter.principal_id
  skip_service_principal_aad_check = true
}

resource "azurerm_role_assignment" "karpenter_node_rg_identity_operator" {
  scope                            = "/subscriptions/${var.subscription_id}/resourceGroups/${azurerm_kubernetes_cluster.main.node_resource_group}"
  role_definition_name             = "Managed Identity Operator"
  principal_id                     = azurerm_user_assigned_identity.karpenter.principal_id
  skip_service_principal_aad_check = true
}

resource "azurerm_role_assignment" "karpenter_vnet_reader" {
  scope                            = local.aks_vnet_id
  role_definition_name             = "Reader"
  principal_id                     = azurerm_user_assigned_identity.karpenter.principal_id
  skip_service_principal_aad_check = true
}

resource "azurerm_role_assignment" "karpenter_subnet_network_contributor" {
  scope                            = local.aks_subnet_id
  role_definition_name             = "Network Contributor"
  principal_id                     = azurerm_user_assigned_identity.karpenter.principal_id
  skip_service_principal_aad_check = true
}

resource "azurerm_role_assignment" "karpenter_kubelet_identity_operator" {
  scope                            = azurerm_kubernetes_cluster.main.kubelet_identity[0].user_assigned_identity_id
  role_definition_name             = "Managed Identity Operator"
  principal_id                     = azurerm_user_assigned_identity.karpenter.principal_id
  skip_service_principal_aad_check = true
}

resource "azurerm_role_assignment" "karpenter_acr_pull" {
  scope                            = azurerm_container_registry.main.id
  role_definition_name             = "AcrPull"
  principal_id                     = azurerm_user_assigned_identity.karpenter.principal_id
  skip_service_principal_aad_check = true
}

resource "azurerm_federated_identity_credential" "karpenter" {
  name                      = "${var.karpenter_identity_name}-fed-cred"
  audience                  = ["api://AzureADTokenExchange"]
  issuer                    = azurerm_kubernetes_cluster.main.oidc_issuer_url
  user_assigned_identity_id = azurerm_user_assigned_identity.karpenter.id
  subject                   = "system:serviceaccount:${var.karpenter_namespace}:${var.karpenter_service_account}"
}

resource "null_resource" "install_karpenter" {
  triggers = {
    cluster_id                 = azurerm_kubernetes_cluster.main.id
    cluster_name               = azurerm_kubernetes_cluster.main.name
    resource_group_name        = azurerm_resource_group.main.name
    acr_name                   = azurerm_container_registry.main.name
    cluster_endpoint           = local.aks_endpoint
    subscription_id            = var.subscription_id
    location                   = var.location
    kubeconfig_path            = local.kubeconfig_path
    system_pool_name           = var.system_pool_name
    karpenter_namespace        = var.karpenter_namespace
    karpenter_service_account  = var.karpenter_service_account
    karpenter_client_id        = azurerm_user_assigned_identity.karpenter.client_id
    karpenter_chart_dir        = local.karpenter_chart_dir
    karpenter_crd_chart_dir    = local.karpenter_crd_chart_dir
    karpenter_chart_hash       = local.karpenter_chart_hash
    karpenter_crd_chart_hash   = local.karpenter_crd_chart_hash
    karpenter_image_repository = var.karpenter_image_repository
    karpenter_image_tag        = var.karpenter_image_tag
    aks_subnet_id              = local.aks_subnet_id
    node_resource_group        = azurerm_kubernetes_cluster.main.node_resource_group
    kubelet_identity_client_id = azurerm_kubernetes_cluster.main.kubelet_identity[0].client_id
    node_identities            = azurerm_kubernetes_cluster.main.kubelet_identity[0].user_assigned_identity_id
    network_plugin             = "azure"
    network_plugin_mode        = "overlay"
    network_policy             = "cilium"
    ssh_public_key             = tls_private_key.aks_admin.public_key_openssh
    gpu_node_image_family      = var.gpu_node_image_family
    gpu_os_disk_size_gb        = tostring(var.gpu_os_disk_size_gb)
    install_gpu_drivers        = tostring(var.install_gpu_drivers)
    gpu_zones_csv              = join(",", local.gpu_zones)
    gpu_sku_name               = var.gpu_sku_name
    gpu_type                   = var.gpu_type
    spot_max_price             = var.spot_max_price
    consolidate_after          = var.consolidate_after
    install_script_sha         = filesha256("${path.module}/scripts/install-karpenter.sh")
    uninstall_script_sha       = filesha256("${path.module}/scripts/uninstall-karpenter.sh")
    helper_script_sha          = filesha256("${path.module}/scripts/common.sh")
  }

  provisioner "local-exec" {
    command     = "bash ${path.module}/scripts/install-karpenter.sh"
    interpreter = ["/bin/bash", "-lc"]

    environment = {
      KUBECONFIG_FILE            = self.triggers.kubeconfig_path
      AZURE_SUBSCRIPTION_ID      = self.triggers.subscription_id
      RESOURCE_GROUP             = self.triggers.resource_group_name
      ACR_NAME                   = self.triggers.acr_name
      LOCATION                   = self.triggers.location
      CLUSTER_NAME               = self.triggers.cluster_name
      AKS_ENDPOINT               = self.triggers.cluster_endpoint
      SYSTEM_POOL_NAME           = self.triggers.system_pool_name
      KARPENTER_NAMESPACE        = self.triggers.karpenter_namespace
      KARPENTER_SERVICE_ACCOUNT  = self.triggers.karpenter_service_account
      KARPENTER_CLIENT_ID        = self.triggers.karpenter_client_id
      KARPENTER_CHART_DIR        = self.triggers.karpenter_chart_dir
      KARPENTER_CRD_CHART_DIR    = self.triggers.karpenter_crd_chart_dir
      KARPENTER_IMAGE_REPOSITORY = self.triggers.karpenter_image_repository
      KARPENTER_IMAGE_TAG        = self.triggers.karpenter_image_tag
      VNET_SUBNET_ID             = self.triggers.aks_subnet_id
      AZURE_NODE_RESOURCE_GROUP  = self.triggers.node_resource_group
      KUBELET_IDENTITY_CLIENT_ID = self.triggers.kubelet_identity_client_id
      NODE_IDENTITIES            = self.triggers.node_identities
      NETWORK_PLUGIN             = self.triggers.network_plugin
      NETWORK_PLUGIN_MODE        = self.triggers.network_plugin_mode
      NETWORK_POLICY             = self.triggers.network_policy
      SSH_PUBLIC_KEY             = self.triggers.ssh_public_key
      GPU_NODE_IMAGE_FAMILY      = self.triggers.gpu_node_image_family
      GPU_OS_DISK_SIZE_GB        = self.triggers.gpu_os_disk_size_gb
      INSTALL_GPU_DRIVERS        = self.triggers.install_gpu_drivers
      GPU_ZONES_CSV              = self.triggers.gpu_zones_csv
      GPU_SKU_NAME               = self.triggers.gpu_sku_name
      GPU_TYPE                   = self.triggers.gpu_type
      SPOT_MAX_PRICE             = self.triggers.spot_max_price
      CONSOLIDATE_AFTER          = self.triggers.consolidate_after
    }
  }

  provisioner "local-exec" {
    when        = destroy
    on_failure  = continue
    command     = "bash ${path.module}/scripts/uninstall-karpenter.sh"
    interpreter = ["/bin/bash", "-lc"]

    environment = {
      KUBECONFIG_FILE          = self.triggers.kubeconfig_path
      AZURE_SUBSCRIPTION_ID    = self.triggers.subscription_id
      RESOURCE_GROUP           = self.triggers.resource_group_name
      CLUSTER_NAME             = self.triggers.cluster_name
      KARPENTER_NAMESPACE      = self.triggers.karpenter_namespace
      KARPENTER_RELEASE_NAME   = "karpenter"
      KARPENTER_CRD_RELEASE    = "karpenter-crd"
      KARPENTER_NODECLASS_NAME = "gpu"
      KARPENTER_SPOT_POOL_NAME = "gpu-spot-pool"
      KARPENTER_OD_POOL_NAME   = "gpu-ondemand-pool"
    }
  }

  depends_on = [
    time_sleep.aks_api_ready,
    null_resource.ama_metrics_config,
    azurerm_federated_identity_credential.karpenter,
    azurerm_role_assignment.karpenter_node_rg_vm_contributor,
    azurerm_role_assignment.karpenter_node_rg_network_contributor,
    azurerm_role_assignment.karpenter_node_rg_identity_operator,
    azurerm_role_assignment.karpenter_vnet_reader,
    azurerm_role_assignment.karpenter_subnet_network_contributor,
    azurerm_role_assignment.karpenter_kubelet_identity_operator,
    azurerm_role_assignment.karpenter_acr_pull,
    null_resource.service_monitor_crd,
  ]
}