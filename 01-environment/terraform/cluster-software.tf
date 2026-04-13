resource "null_resource" "prepare_aks_kubeconfig" {
  triggers = {
    cluster_id          = azurerm_kubernetes_cluster.main.id
    subscription_id     = var.subscription_id
    resource_group_name = azurerm_resource_group.main.name
    cluster_name        = azurerm_kubernetes_cluster.main.name
    kubeconfig_path     = local.kubeconfig_path
    helper_script_sha   = filesha256("${path.module}/scripts/common.sh")
    writer_script_sha   = filesha256("${path.module}/scripts/write-kubeconfig.sh")
  }

  provisioner "local-exec" {
    command     = "bash ${path.module}/scripts/write-kubeconfig.sh"
    interpreter = ["/bin/bash", "-lc"]

    environment = {
      KUBECONFIG_FILE       = self.triggers.kubeconfig_path
      AZURE_SUBSCRIPTION_ID = self.triggers.subscription_id
      RESOURCE_GROUP        = self.triggers.resource_group_name
      CLUSTER_NAME          = self.triggers.cluster_name
    }
  }

  depends_on = [azurerm_kubernetes_cluster.main]
}

resource "time_sleep" "aks_api_ready" {
  create_duration = "30s"

  depends_on = [
    azurerm_kubernetes_cluster.main,
    null_resource.prepare_aks_kubeconfig,
  ]
}

resource "null_resource" "service_monitor_crd" {
  count = var.service_monitor_crd_enabled ? 1 : 0

  triggers = {
    cluster_id          = azurerm_kubernetes_cluster.main.id
    subscription_id     = var.subscription_id
    resource_group_name = azurerm_resource_group.main.name
    cluster_name        = azurerm_kubernetes_cluster.main.name
    kubeconfig_path     = local.kubeconfig_path
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

resource "null_resource" "ama_metrics_config" {
  triggers = {
    cluster_id          = azurerm_kubernetes_cluster.main.id
    subscription_id     = var.subscription_id
    resource_group_name = azurerm_resource_group.main.name
    cluster_name        = azurerm_kubernetes_cluster.main.name
    kubeconfig_path     = local.kubeconfig_path
    config_file         = local.ama_metrics_config
    config_file_hash    = local.ama_metrics_config_hash
    install_script_sha  = filesha256("${path.module}/scripts/apply-ama-metrics-config.sh")
    helper_script_sha   = filesha256("${path.module}/scripts/common.sh")
  }

  provisioner "local-exec" {
    command     = "bash ${path.module}/scripts/apply-ama-metrics-config.sh"
    interpreter = ["/bin/bash", "-lc"]

    environment = {
      KUBECONFIG_FILE         = self.triggers.kubeconfig_path
      AZURE_SUBSCRIPTION_ID   = self.triggers.subscription_id
      RESOURCE_GROUP          = self.triggers.resource_group_name
      CLUSTER_NAME            = self.triggers.cluster_name
      AMA_METRICS_CONFIG_FILE = self.triggers.config_file
    }
  }

  depends_on = [time_sleep.aks_api_ready]
}

resource "null_resource" "persist_aks_kubeconfig" {
  triggers = {
    cluster_id          = azurerm_kubernetes_cluster.main.id
    subscription_id     = var.subscription_id
    resource_group_name = azurerm_resource_group.main.name
    cluster_name        = azurerm_kubernetes_cluster.main.name
    kubeconfig_path     = local.kubeconfig_path
    helper_script_sha   = filesha256("${path.module}/scripts/common.sh")
    writer_script_sha   = filesha256("${path.module}/scripts/write-kubeconfig.sh")
  }

  provisioner "local-exec" {
    command     = "bash ${path.module}/scripts/write-kubeconfig.sh"
    interpreter = ["/bin/bash", "-lc"]

    environment = {
      KUBECONFIG_FILE       = self.triggers.kubeconfig_path
      AZURE_SUBSCRIPTION_ID = self.triggers.subscription_id
      RESOURCE_GROUP        = self.triggers.resource_group_name
      CLUSTER_NAME          = self.triggers.cluster_name
    }
  }

  depends_on = [
    null_resource.install_karpenter,
    null_resource.install_istio_addons,
    null_resource.install_gpu_operator,
  ]
}