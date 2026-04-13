# Shell Workflow

这里保留现有 shell 版环境搭建流程，适合作为 Terraform 之外的运维入口。

## 目录内容

- 14-sync-helm-images.sh: 独立把 Karpenter / GPU Operator 等用户侧 Helm 镜像同步到当前 ACR。
- 05-create-network.sh: 创建或复用自定义 VNet/Subnet。
- 06-destroy-network.sh: 删除单独的网络资源组。
- 10-create-aks.sh: 创建 ACR、监控资源和 AKS 集群。
- 11-delete-aks.sh: 删除 AKS。
- 15-deploy-karpenter.sh: 安装 Karpenter 并创建 GPU NodePool。
- 16-destroy-karpenter.sh: 卸载 Karpenter。
- 17-deploy-gpu-operator.sh: 安装 GPU Operator 并创建 NVIDIADriver。
- 18-destroy-gpu-operator.sh: 卸载 GPU Operator。
- 99-cleanup.sh: 一键回收环境资源。

## 前置条件

- 已安装并登录 Azure CLI。
- 已安装 kubectl、helm、docker、python3。
- 根目录下准备好 aks.env。

```bash
cp aks.env.sample aks.env
```

## 使用顺序

```bash
./01-environment/shell/05-create-network.sh
./01-environment/shell/10-create-aks.sh
./01-environment/shell/14-sync-helm-images.sh
./01-environment/shell/15-deploy-karpenter.sh
./01-environment/shell/17-deploy-gpu-operator.sh
```

说明：14 这一步不是必须，因为 15/17 现在也会自动把各自依赖的上游镜像同步到 ACR；但在受限网络或需要提前预热镜像时，建议先单独执行一次。

## Charts 位置

shell 流程依赖 vendored Helm charts，统一放在 01-environment/charts 下。

默认行为：10-create-aks.sh 会显式开启 AKS Azure Blob CSI Driver；如果集群已存在但该驱动未开启，脚本也会执行一次 `az aks update --enable-blob-driver` 做对齐。

```bash
cp -r /path/to/karpenter-provider-azure/charts/karpenter-crd 01-environment/charts/
cp -r /path/to/karpenter-provider-azure/charts/karpenter 01-environment/charts/

helm repo add nvidia https://helm.ngc.nvidia.com/nvidia
helm pull nvidia/gpu-operator --version v25.3.4 --untar -d 01-environment/charts/
```

## 清理

```bash
./01-environment/shell/99-cleanup.sh
DELETE_RESOURCE_GROUP=true ./01-environment/shell/99-cleanup.sh
DELETE_RESOURCE_GROUP=true DELETE_NETWORK_RESOURCE_GROUP=true ./01-environment/shell/99-cleanup.sh
```