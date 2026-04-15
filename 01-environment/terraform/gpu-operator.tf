resource "null_resource" "install_gpu_operator" {
  count = var.gpu_operator_enabled ? 1 : 0

  triggers = {
    cluster_id                        = azurerm_kubernetes_cluster.main.id
    kubeconfig_path                   = local.kubeconfig_path
    subscription_id                   = var.subscription_id
    resource_group_name               = azurerm_resource_group.main.name
    cluster_name                      = azurerm_kubernetes_cluster.main.name
    acr_name                          = local.acr_name
    gpu_operator_chart_dir            = local.gpu_operator_chart_dir
    gpu_operator_chart_hash           = local.gpu_operator_chart_hash
    gpu_operator_namespace            = var.gpu_operator_namespace
    gpu_driver_cr_name                = var.gpu_driver_cr_name
    gpu_driver_node_selector_key      = var.gpu_driver_node_selector_key
    gpu_driver_node_selector_value    = local.gpu_driver_node_selector_value
    gpu_driver_source_repository      = var.gpu_driver_source_repository
    gpu_driver_image                  = var.gpu_driver_image
    gpu_driver_version                = var.gpu_driver_version
    gpu_driver_require_matching_nodes = tostring(var.gpu_driver_require_matching_nodes)
    gpu_driver_sync_enabled           = tostring(var.gpu_driver_sync_enabled)
    gpu_driver_sync_use_sudo          = tostring(var.gpu_driver_sync_use_sudo)
    gpu_driver_allow_os_tag_alias     = tostring(var.gpu_driver_allow_os_tag_alias)
    gpu_driver_source_tag_2204        = local.gpu_driver_version_source_tag_2204
    gpu_driver_source_tag_2404        = local.gpu_driver_version_source_tag_2404
    gpu_node_workload_label           = var.gpu_node_workload_label
    install_script_sha                = filesha256("${path.module}/scripts/install-gpu-operator.sh")
    uninstall_script_sha              = filesha256("${path.module}/scripts/uninstall-gpu-operator.sh")
    helper_script_sha                 = filesha256("${path.module}/scripts/common.sh")
  }

  provisioner "local-exec" {
    command     = "bash ${path.module}/scripts/install-gpu-operator.sh"
    interpreter = ["/bin/bash", "-lc"]

    environment = {
      SHARED_ENV_FILE                   = local.shared_env_file
      KUBECONFIG_FILE                   = self.triggers.kubeconfig_path
      AZURE_SUBSCRIPTION_ID             = self.triggers.subscription_id
      RESOURCE_GROUP                    = self.triggers.resource_group_name
      CLUSTER_NAME                      = self.triggers.cluster_name
      GPU_OPERATOR_CHART_DIR            = self.triggers.gpu_operator_chart_dir
      GPU_OPERATOR_NAMESPACE            = self.triggers.gpu_operator_namespace
      GPU_DRIVER_CR_NAME                = self.triggers.gpu_driver_cr_name
      GPU_DRIVER_NODE_SELECTOR_KEY      = self.triggers.gpu_driver_node_selector_key
      GPU_DRIVER_NODE_SELECTOR_VALUE    = self.triggers.gpu_driver_node_selector_value
      GPU_DRIVER_IMAGE                  = self.triggers.gpu_driver_image
      GPU_DRIVER_VERSION                = self.triggers.gpu_driver_version
      GPU_DRIVER_REQUIRE_MATCHING_NODES = self.triggers.gpu_driver_require_matching_nodes
      GPU_NODE_WORKLOAD_LABEL           = self.triggers.gpu_node_workload_label
    }
  }

  provisioner "local-exec" {
    when        = destroy
    on_failure  = continue
    command     = "bash ${path.module}/scripts/uninstall-gpu-operator.sh"
    interpreter = ["/bin/bash", "-lc"]

    environment = {
      KUBECONFIG_FILE        = self.triggers.kubeconfig_path
      AZURE_SUBSCRIPTION_ID  = self.triggers.subscription_id
      RESOURCE_GROUP         = self.triggers.resource_group_name
      CLUSTER_NAME           = self.triggers.cluster_name
      GPU_OPERATOR_NAMESPACE = self.triggers.gpu_operator_namespace
      GPU_DRIVER_CR_NAME     = self.triggers.gpu_driver_cr_name
    }
  }

  depends_on = [
    null_resource.prepare_shared_assets,
    null_resource.install_karpenter,
  ]
}