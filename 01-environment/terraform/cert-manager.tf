resource "null_resource" "install_cert_manager" {
  count = var.cert_manager_enabled ? 1 : 0

  lifecycle {
    precondition {
      condition     = trimspace(var.cert_manager_acme_email) != ""
      error_message = "cert_manager_acme_email must be set when cert_manager_enabled is true."
    }
  }

  triggers = {
    cluster_id                        = azurerm_kubernetes_cluster.main.id
    kubeconfig_path                   = local.kubeconfig_path
    subscription_id                   = var.subscription_id
    resource_group_name               = azurerm_resource_group.main.name
    cluster_name                      = azurerm_kubernetes_cluster.main.name
    cert_manager_acme_email           = var.cert_manager_acme_email
    cert_manager_staging_issuer_name  = var.cert_manager_staging_issuer_name
    cert_manager_prod_issuer_name     = var.cert_manager_prod_issuer_name
    cert_manager_manifest_hash        = local.cert_manager_manifest_hash
    cert_manager_issuer_template_hash = local.cert_manager_issuer_template_hash
    install_script_sha                = filesha256("${path.module}/../scripts/install-cert-manager.sh")
    uninstall_script_sha              = filesha256("${path.module}/../scripts/uninstall-cert-manager.sh")
  }

  provisioner "local-exec" {
    command     = "bash ${path.module}/../scripts/install-cert-manager.sh"
    interpreter = ["/bin/bash", "-lc"]

    environment = {
      KUBECONFIG_FILE                  = self.triggers.kubeconfig_path
      AZURE_SUBSCRIPTION_ID            = self.triggers.subscription_id
      RESOURCE_GROUP                   = self.triggers.resource_group_name
      CLUSTER_NAME                     = self.triggers.cluster_name
      CERT_MANAGER_ACME_EMAIL          = self.triggers.cert_manager_acme_email
      CERT_MANAGER_STAGING_ISSUER_NAME = self.triggers.cert_manager_staging_issuer_name
      CERT_MANAGER_PROD_ISSUER_NAME    = self.triggers.cert_manager_prod_issuer_name
    }
  }

  provisioner "local-exec" {
    when        = destroy
    on_failure  = continue
    command     = "bash ${path.module}/../scripts/uninstall-cert-manager.sh"
    interpreter = ["/bin/bash", "-lc"]

    environment = {
      KUBECONFIG_FILE                  = self.triggers.kubeconfig_path
      AZURE_SUBSCRIPTION_ID            = self.triggers.subscription_id
      RESOURCE_GROUP                   = self.triggers.resource_group_name
      CLUSTER_NAME                     = self.triggers.cluster_name
      CERT_MANAGER_STAGING_ISSUER_NAME = self.triggers.cert_manager_staging_issuer_name
      CERT_MANAGER_PROD_ISSUER_NAME    = self.triggers.cert_manager_prod_issuer_name
    }
  }

  depends_on = [
    null_resource.wait_for_managed_gateway_api,
    null_resource.install_istio_addons,
  ]
}