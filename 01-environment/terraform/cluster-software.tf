resource "local_file" "aks_kubeconfig" {
  content              = azurerm_kubernetes_cluster.main.kube_admin_config_raw
  filename             = local.kubeconfig_path
  file_permission      = "0600"
  directory_permission = "0700"
}

resource "time_sleep" "aks_api_ready" {
  create_duration = "30s"

  depends_on = [
    azurerm_kubernetes_cluster.main,
    local_file.aks_kubeconfig,
  ]
}

resource "null_resource" "service_monitor_crd" {
  count = var.service_monitor_crd_enabled ? 1 : 0

  triggers = {
    cluster_id          = azurerm_kubernetes_cluster.main.id
    subscription_id     = var.subscription_id
    resource_group_name = azurerm_resource_group.main.name
    cluster_name        = azurerm_kubernetes_cluster.main.name
    kubeconfig_path     = local_file.aks_kubeconfig.filename
    crd_file            = local.service_monitor_crd
    crd_file_hash       = local.service_monitor_crd_hash
    install_script_sha  = filesha256("${path.module}/scripts/apply-servicemonitor-crd.sh")
    helper_script_sha   = filesha256("${path.module}/scripts/common.sh")
  }

  provisioner "local-exec" {
    command     = "bash ${path.module}/scripts/apply-servicemonitor-crd.sh"
    interpreter = ["/bin/bash", "-lc"]

    environment = {
      KUBECONFIG_FILE          = self.triggers.kubeconfig_path
      AZURE_SUBSCRIPTION_ID    = self.triggers.subscription_id
      RESOURCE_GROUP           = self.triggers.resource_group_name
      CLUSTER_NAME             = self.triggers.cluster_name
      SERVICE_MONITOR_CRD_FILE = self.triggers.crd_file
    }
  }

  depends_on = [time_sleep.aks_api_ready]
}