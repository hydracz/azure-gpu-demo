variable "subscription_id" {
  description = "Azure subscription id"
  type        = string
}

variable "location" {
  description = "Azure region"
  type        = string
}

variable "resource_group_name" {
  description = "Primary resource group for the environment"
  type        = string
}

variable "cluster_name" {
  description = "AKS cluster name"
  type        = string
}

variable "acr_name" {
  description = "Azure Container Registry name"
  type        = string
}

variable "monitor_workspace_name" {
  description = "Azure Monitor Workspace name"
  type        = string
}

variable "monitor_workspace_public_network_access_enabled" {
  description = "Whether Azure Monitor Workspace public network access is enabled"
  type        = bool
  default     = true
}

variable "log_analytics_workspace_name" {
  description = "Log Analytics workspace name"
  type        = string
}

variable "grafana_name" {
  description = "Managed Grafana name"
  type        = string
}

variable "grafana_major_version" {
  description = "Managed Grafana major version"
  type        = number
  default     = 11
}

variable "diagnostic_setting_name" {
  description = "AKS diagnostic setting name"
  type        = string
  default     = "aks-all-logs"
}

variable "existing_subnet_id" {
  description = "Existing AKS subnet id. Leave empty to create network resources in Terraform."
  type        = string
  default     = ""
}

variable "network_resource_group_name" {
  description = "Network resource group name when Terraform manages the VNet"
  type        = string
  default     = ""
}

variable "vnet_name" {
  description = "VNet name when Terraform manages the network"
  type        = string
  default     = ""
}

variable "vnet_address_space" {
  description = "Address space for the managed VNet"
  type        = list(string)
  default     = ["10.240.0.0/16"]
}

variable "aks_subnet_name" {
  description = "AKS subnet name when Terraform manages the network"
  type        = string
  default     = "snet-aks-underlay"
}

variable "aks_subnet_address_prefixes" {
  description = "Address prefixes for the AKS subnet when Terraform manages the network"
  type        = list(string)
  default     = ["10.240.0.0/20"]
}

variable "system_pool_name" {
  description = "AKS system node pool name"
  type        = string
  default     = "sysd4"
}

variable "system_vm_size" {
  description = "AKS system node pool VM size"
  type        = string
  default     = "Standard_D4ads_v6"
}

variable "system_node_count" {
  description = "AKS system node pool node count"
  type        = number
  default     = 3
}

variable "aks_admin_username" {
  description = "Linux admin username for AKS node access"
  type        = string
  default     = "azureuser"
}

variable "service_cidr" {
  description = "AKS service CIDR"
  type        = string
  default     = "172.16.32.0/19"
}

variable "dns_service_ip" {
  description = "AKS DNS service IP"
  type        = string
  default     = "172.16.32.10"
}

variable "blob_driver_enabled" {
  description = "Whether the AKS Azure Blob CSI driver is enabled"
  type        = bool
  default     = true
}

variable "istio_service_mesh_enabled" {
  description = "Whether to enable the AKS managed Istio-based service mesh add-on (ASM)"
  type        = bool
  default     = true
}

variable "istio_revisions" {
  description = "Istio control plane revisions for the AKS managed service mesh add-on. Defaults to asm-1-27; set to [] to let AKS choose the default supported revision."
  type        = list(string)
  default     = ["asm-1-27"]
}

variable "istio_internal_ingress_gateway_enabled" {
  description = "Whether to enable the AKS managed Istio internal ingress gateway"
  type        = bool
  default     = false
}

variable "istio_external_ingress_gateway_enabled" {
  description = "Whether to enable the AKS managed Istio external ingress gateway"
  type        = bool
  default     = true
}

variable "grafana_admin_principal_ids" {
  description = "Principal ids that should receive Grafana Admin on the Managed Grafana resource"
  type        = list(string)
  default     = []
}

variable "grafana_public_network_access_enabled" {
  description = "Whether Managed Grafana public network access is enabled"
  type        = bool
  default     = true
}

variable "prometheus_rule_group_enabled" {
  description = "Whether managed Prometheus rule groups are enabled"
  type        = bool
  default     = true
}

variable "prometheus_rule_group_interval" {
  description = "Evaluation interval for managed Prometheus rule groups"
  type        = string
  default     = "PT1M"
}

variable "service_monitor_crd_enabled" {
  description = "Whether to install the ServiceMonitor CRD before Helm workloads"
  type        = bool
  default     = true
}

variable "karpenter_namespace" {
  description = "Namespace for Karpenter"
  type        = string
  default     = "kube-system"
}

variable "karpenter_service_account" {
  description = "Service account name for Karpenter workload identity"
  type        = string
  default     = "karpenter-sa"
}

variable "karpenter_identity_name" {
  description = "User assigned managed identity name for Karpenter"
  type        = string
  default     = "id-karpenter-gpu"
}

variable "karpenter_image_repository" {
  description = "Container image repository for the Karpenter controller"
  type        = string
  default     = "quay.io/hydracz/karpenter-controller"
}

variable "karpenter_image_tag" {
  description = "Container image tag for the Karpenter controller"
  type        = string
  default     = "v20260323-dev"
}

variable "gpu_sku_name" {
  description = "Azure VM SKU for GPU nodes"
  type        = string
  default     = "Standard_NC128lds_xl_RTXPRO6000BSE_v6"
}

variable "gpu_type" {
  description = "GPU type label applied to Karpenter nodes"
  type        = string
  default     = "rtxpro6000-bse"
}

variable "gpu_zones" {
  description = "Availability zones used by the GPU node pools"
  type        = list(string)
  default     = []
}

variable "gpu_node_image_family" {
  description = "AKSNodeClass image family for GPU nodes"
  type        = string
  default     = "Ubuntu2404"
}

variable "gpu_os_disk_size_gb" {
  description = "OS disk size for GPU nodes"
  type        = number
  default     = 1024
}

variable "install_gpu_drivers" {
  description = "Whether AKSNodeClass should install GPU drivers directly"
  type        = bool
  default     = false
}

variable "consolidate_after" {
  description = "Karpenter consolidateAfter value for GPU node pools"
  type        = string
  default     = "10m"
}

variable "spot_max_price" {
  description = "Maximum Spot price annotation for the spot GPU node pool"
  type        = string
  default     = "-1"
}

variable "gpu_operator_enabled" {
  description = "Whether to deploy the vendored NVIDIA GPU Operator"
  type        = bool
  default     = true
}

variable "gpu_operator_namespace" {
  description = "Namespace for the NVIDIA GPU Operator"
  type        = string
  default     = "gpu-operator"
}

variable "gpu_driver_cr_name" {
  description = "Name of the NVIDIADriver custom resource"
  type        = string
  default     = "rtxpro6000-azure"
}

variable "gpu_driver_node_selector_key" {
  description = "Node selector key used by NVIDIADriver"
  type        = string
  default     = "karpenter.azure.com/sku-gpu-name"
}

variable "gpu_driver_node_selector_value" {
  description = "Node selector value used by NVIDIADriver. Leave empty to derive it from gpu_sku_name."
  type        = string
  default     = ""
}

variable "gpu_driver_source_repository" {
  description = "Source repository for synced GPU driver images"
  type        = string
  default     = "docker.io/yingeli"
}

variable "gpu_driver_image" {
  description = "Driver image name"
  type        = string
  default     = "driver"
}

variable "gpu_driver_version" {
  description = "Driver image version"
  type        = string
  default     = "580.105.08"
}

variable "gpu_driver_require_matching_nodes" {
  description = "Whether to fail if no current nodes match the GPU driver selector"
  type        = bool
  default     = false
}

variable "gpu_driver_sync_enabled" {
  description = "Whether to sync GPU driver images into the target ACR"
  type        = bool
  default     = true
}

variable "gpu_driver_sync_use_sudo" {
  description = "Whether skopeo should be run through sudo during GPU driver sync"
  type        = bool
  default     = false
}

variable "gpu_driver_allow_os_tag_alias" {
  description = "Whether GPU driver sync may alias source tags to a different target OS tag"
  type        = bool
  default     = false
}

variable "gpu_driver_version_source_tag_2204" {
  description = "Source tag used for the Ubuntu 22.04 GPU driver image. Leave empty to derive it from gpu_driver_version."
  type        = string
  default     = ""
}

variable "gpu_driver_version_source_tag_2404" {
  description = "Source tag used for the Ubuntu 24.04 GPU driver image. Leave empty to derive it from gpu_driver_version."
  type        = string
  default     = ""
}

variable "tags" {
  description = "Additional resource tags"
  type        = map(string)
  default     = {}
}