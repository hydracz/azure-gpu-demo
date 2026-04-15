resource "null_resource" "prepare_shared_assets" {
  triggers = {
    subscription_id                = var.subscription_id
    location                       = var.location
    resource_group_name            = azurerm_resource_group.main.name
    acr_id                         = local.acr_id
    acr_name                       = local.acr_name
    acr_login_server               = local.acr_login_server
    aks_subnet_id                  = local.aks_subnet_id
    shared_env_file                = local.shared_env_file
    karpenter_image_repository     = var.karpenter_image_repository
    karpenter_image_tag            = var.karpenter_image_tag
    gpu_operator_chart_hash        = local.gpu_operator_chart_hash
    gpu_driver_source_repository   = var.gpu_driver_source_repository
    gpu_driver_image               = var.gpu_driver_image
    gpu_driver_version             = var.gpu_driver_version
    gpu_driver_sync_enabled        = tostring(var.gpu_driver_sync_enabled)
    gpu_driver_source_tag_2204     = local.gpu_driver_version_source_tag_2204
    gpu_driver_source_tag_2404     = local.gpu_driver_version_source_tag_2404
    istio_kiali_enabled            = tostring(var.istio_kiali_enabled)
    istio_kiali_operator_chart_ver = var.istio_kiali_operator_chart_version
    prepare_entry_sha              = filesha256("${path.module}/../../00-prepare/00-prepare.sh")
    prepare_acr_script_sha         = filesha256("${path.module}/../../00-prepare/scripts/prepare-acr.sh")
    prepare_network_script_sha     = filesha256("${path.module}/../../00-prepare/scripts/prepare-network.sh")
    prepare_script_sha             = filesha256("${path.module}/../../00-prepare/scripts/prepare-shared-assets.sh")
    helper_script_sha              = filesha256("${path.module}/scripts/common.sh")
    image_sync_lib_sha             = filesha256("${path.module}/../../00-prepare/scripts/image-sync-lib.sh")
    karpenter_image_sync_sha       = filesha256("${path.module}/../../00-prepare/scripts/karpenter-image-sync.sh")
    gpu_operator_image_sync_sha    = filesha256("${path.module}/../../00-prepare/scripts/gpu-operator-image-sync.sh")
    kiali_image_sync_sha           = filesha256("${path.module}/../../00-prepare/scripts/kiali-image-sync.sh")
  }

  provisioner "local-exec" {
    command     = "bash ${path.module}/../../00-prepare/00-prepare.sh"
    interpreter = ["/bin/bash", "-lc"]

    environment = {
      SHARED_ENV_FILE                    = self.triggers.shared_env_file
      AZURE_SUBSCRIPTION_ID              = self.triggers.subscription_id
      LOCATION                           = self.triggers.location
      RESOURCE_GROUP                     = self.triggers.resource_group_name
      EXISTING_ACR_ID                    = self.triggers.acr_id
      ACR_NAME                           = self.triggers.acr_name
      ACR_LOGIN_SERVER                   = self.triggers.acr_login_server
      EXISTING_VNET_SUBNET_ID            = self.triggers.aks_subnet_id
      KARPENTER_IMAGE_REPOSITORY         = self.triggers.karpenter_image_repository
      KARPENTER_IMAGE_TAG                = self.triggers.karpenter_image_tag
      GPU_DRIVER_SOURCE_REPOSITORY       = self.triggers.gpu_driver_source_repository
      GPU_DRIVER_IMAGE                   = self.triggers.gpu_driver_image
      GPU_DRIVER_VERSION                 = self.triggers.gpu_driver_version
      GPU_DRIVER_SYNC_ENABLED            = self.triggers.gpu_driver_sync_enabled
      GPU_DRIVER_VERSION_SOURCE_TAG_2204 = self.triggers.gpu_driver_source_tag_2204
      GPU_DRIVER_VERSION_SOURCE_TAG_2404 = self.triggers.gpu_driver_source_tag_2404
      ISTIO_KIALI_ENABLED                = self.triggers.istio_kiali_enabled
      ISTIO_KIALI_OPERATOR_CHART_VERSION = self.triggers.istio_kiali_operator_chart_ver
    }
  }
}