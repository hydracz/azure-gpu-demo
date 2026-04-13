# Terraform Workflow

这一套实现参考了 terraform-infra-setup 的使用习惯：Terraform 文件平铺在目录根部，用少量 shell 脚本包裹 init、plan、apply、destroy，并通过独立的环境文件切换部署参数。

## 资源范围

当前 Terraform 覆盖以下资源与集群内安装动作：

- Resource Group
- 可选的独立网络 Resource Group、VNet、AKS Subnet
- Azure Container Registry
- Azure Monitor Workspace
- Log Analytics Workspace
- Managed Grafana
- AKS 集群
- AKS Blob CSI Driver 默认开启
- AKS 到 ACR 的 AcrPull 授权
- Managed Prometheus Data Collection Rule 与 Association
- Managed Prometheus Node / Kubernetes recording rule groups
- AKS 诊断设置
- ServiceMonitor CRD
- Karpenter Managed Identity、Federated Credential、Azure RBAC
- Karpenter Helm charts、AKSNodeClass、GPU NodePool
- GPU Operator Helm chart、驱动镜像同步、NVIDIADriver

## 初始化文件

复制样例并生成你自己的环境文件：

```bash
cd 01-environment/terraform
cp tfvar.sample dev.tfvar
cp tfbackend.sample dev.tfbackend
```

## 执行顺序

```bash
./00-init.sh dev
./01-plan.sh dev
./02-apply.sh dev
```

销毁环境：

```bash
./03-destroy.sh dev
```

## 说明

- 与参考仓库一致，环境名作为脚本参数，脚本会读取同目录下的 dev.tfvar 和 dev.tfbackend。
- 如果已有预创建子网，填写 existing_subnet_id 即可跳过网络资源创建。
- 如果希望 Terraform 创建网络，则留空 existing_subnet_id，并设置 network_resource_group_name、vnet_name、vnet_address_space、aks_subnet_name、aks_subnet_address_prefixes。
- Managed Grafana 管理员通过 grafana_admin_principal_ids 传入，不在代码里猜测当前登录身份。
- Managed Grafana 会自动集成 Azure Monitor Workspace，并补齐对 Monitor Workspace 的 Monitoring Data Reader / Monitoring Metrics Publisher 权限。
- AKS 监控不只开启 monitor_metrics，还会创建 Managed Prometheus 的 DCR、DCRA，以及基础 recording rules。
- AKS 默认开启 Azure Blob CSI Driver，对应 az aks create/update 的 --enable-blob-driver；如需关闭，可把 blob_driver_enabled 设为 false。
- 这一版 Terraform 会在 apply 阶段通过本机的 az、kubectl、helm、python3、skopeo 执行集群内软件安装，职责已经与 shell 版本基本对齐。
- 如果只想保留基础 Azure 资源，不想在 Terraform 中安装 Karpenter 或 GPU Operator，可以把 gpu_operator_enabled 设为 false，或按需移除对应 null_resource。