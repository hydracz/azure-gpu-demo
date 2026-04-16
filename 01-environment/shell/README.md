# Shell Workflow

这里保留现有 shell 版环境搭建流程，适合作为 Terraform 之外的运维入口。

## 目录内容

- 10-create-aks.sh: 创建监控资源和 AKS 集群，并前置启用 AKS managed Gateway API、AKS managed Istio 与共享 KEDA Prometheus 认证；默认直接消费 00-prepare 阶段准备好的 subnet 和 ACR。
- 12-deploy-cert-manager.sh: 安装 cert-manager，并以 Gateway API HTTP-01 solver 方式创建 Let's Encrypt staging/prod ClusterIssuer。
- 13-destroy-cert-manager.sh: 删除 cert-manager 和 Let's Encrypt ClusterIssuer。
- 19-import-grafana-dashboards.sh: 把仓库内置的 Grafana 仪表板导入到当前 Azure Managed Grafana。
- 11-delete-aks.sh: 删除 AKS。
- 15-deploy-karpenter.sh: 安装 Karpenter 并创建 GPU NodePool，只读取 00-prepare 已写入的镜像仓库和网络信息。
- 16-destroy-karpenter.sh: 卸载 Karpenter。
- 17-deploy-gpu-operator.sh: 安装 GPU Operator 并创建 NVIDIADriver，只读取 00-prepare 已写入的镜像仓库信息。
- 18-destroy-gpu-operator.sh: 卸载 GPU Operator。
- 99-cleanup.sh: 一键回收环境资源。

## 前置条件

- 已安装并登录 Azure CLI。
- 已安装 kubectl、helm、docker、python3。
- 根目录下准备好 aks.env。它现在也是 Terraform 的统一输入源，不再只是 shell 专用配置。

```bash
cp aks.env.sample aks.env
```

## 使用顺序

```bash
./01-environment/shell/10-create-aks.sh
./01-environment/shell/15-deploy-karpenter.sh
./01-environment/shell/17-deploy-gpu-operator.sh
```

运行这个 shell 流程之前，先完成仓库顶层的共享准备步骤；01 不会帮你补镜像同步或网络创建，只会消费并校验 .generated.env / aks.env 中已有结果。

说明：10-create-aks.sh 现在会自动调用 12-deploy-cert-manager.sh，因此正常场景不需要单独执行 12；如果你只想重试证书平台安装，再单独运行 12 即可。

说明：10-create-aks.sh 也会自动调用 19-import-grafana-dashboards.sh，把 Istio workload 看板和当前仓库兼容的 GPU DCGM 看板导入到 Azure Managed Grafana；如果只想重试 dashboard 导入，可单独运行 19。

## Charts 位置

shell 流程依赖 vendored Helm charts，统一放在 01-environment/charts 下。

默认行为：10-create-aks.sh 会显式开启 AKS Azure Blob CSI Driver；如果集群已存在但该驱动未开启，脚本也会执行一次 `az aks update --enable-blob-driver` 做对齐。

同时，10-create-aks.sh 现在会默认确保以下平台能力已经就绪：

- AKS managed Istio (`asm-1-27`)
- AKS managed Gateway API
- external ingress gateway
- internal ingress gateway
- cert-manager
- Let's Encrypt `ClusterIssuer`（staging / prod）
- Azure Managed Grafana dashboard 导入（Istio workload + AKS GPU DCGM）
- KEDA operator 访问 Azure Managed Prometheus 所需的 shared workload identity 和 `ClusterTriggerAuthentication`

启用 cert-manager 时，需要在根目录 `aks.env` 里提供 `CERT_MANAGER_ACME_EMAIL`。后续 workload 默认直接使用 `letsencrypt-prod` 签发证书。

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
```