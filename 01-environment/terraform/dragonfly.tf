resource "null_resource" "install_dragonfly" {
  count = var.dragonfly_enabled ? 1 : 0

  triggers = {
    cluster_id           = azurerm_kubernetes_cluster.main.id
    subscription_id      = var.subscription_id
    resource_group_name  = azurerm_resource_group.main.name
    cluster_name         = azurerm_kubernetes_cluster.main.name
    kubeconfig_path      = local.kubeconfig_path
    shared_env_file      = local.shared_env_file
    shared_env_hash      = fileexists(local.shared_env_file) ? filesha256(local.shared_env_file) : ""
    dragonfly_chart_hash = local.dragonfly_chart_hash
    install_script_sha   = filesha256("${path.module}/../shell/20-deploy-dragonfly.sh")
    uninstall_script_sha = filesha256("${path.module}/../shell/22-destroy-dragonfly.sh")
  }

  provisioner "local-exec" {
    command     = "bash ${path.module}/../shell/20-deploy-dragonfly.sh"
    interpreter = ["/bin/bash", "-lc"]

    environment = {
      SHARED_ENV_FILE     = self.triggers.shared_env_file
      KUBECONFIG          = self.triggers.kubeconfig_path
      AKS_KUBECONFIG_FILE = self.triggers.kubeconfig_path
      AZ_SUBSCRIPTION_ID  = self.triggers.subscription_id
      RESOURCE_GROUP      = self.triggers.resource_group_name
      CLUSTER_NAME        = self.triggers.cluster_name
      ACR_LOGIN_SERVER    = local.acr_login_server
    }
  }

  provisioner "local-exec" {
    when        = destroy
    on_failure  = continue
    command     = "bash ${path.module}/../shell/22-destroy-dragonfly.sh"
    interpreter = ["/bin/bash", "-lc"]

    environment = {
      SHARED_ENV_FILE     = self.triggers.shared_env_file
      KUBECONFIG          = self.triggers.kubeconfig_path
      AKS_KUBECONFIG_FILE = self.triggers.kubeconfig_path
      AZ_SUBSCRIPTION_ID  = self.triggers.subscription_id
      RESOURCE_GROUP      = self.triggers.resource_group_name
      CLUSTER_NAME        = self.triggers.cluster_name
    }
  }

  depends_on = [
    null_resource.persist_aks_kubeconfig,
  ]
}