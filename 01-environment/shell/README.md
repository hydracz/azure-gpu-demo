# Shell Workflow

这里保留现有 shell 版环境搭建流程，适合作为 Terraform 之外的运维入口。

## 目录内容

- 10-create-aks.sh: 创建监控资源和 AKS 集群，并前置启用 AKS managed Gateway API、AKS managed Istio 与共享 KEDA Prometheus 认证；默认直接消费 00-prepare 阶段准备好的 subnet 和 ACR。
- 12-deploy-cert-manager.sh: 安装 cert-manager，并以 Gateway API HTTP-01 solver 方式创建 Let's Encrypt staging/prod ClusterIssuer。
- 13-destroy-cert-manager.sh: 删除 cert-manager 和 Let's Encrypt ClusterIssuer。
- 19-import-grafana-dashboards.sh: 把仓库内置的 Grafana 仪表板导入到当前 Azure Managed Grafana。
- 11-delete-aks.sh: 删除 AKS。
- 20-deploy-dragonfly.sh: 安装 Dragonfly；manager / scheduler 留在 system pool，seed-client 固定跑在 on-demand GPU 节点，client DaemonSet 绑定到全部 GPU 节点。对于 Ubuntu2404 + NVIDIA toolkit 的 GPU 节点，不再依赖 dfinit 直接改主配置，而是通过独立的 containerd configurer DaemonSet 往 /etc/containerd/conf.d 和 /etc/containerd/certs.d 写入 drop-in / hosts.toml，使 Dragonfly 与 nvidia-container-toolkit 共存。
- 22-destroy-dragonfly.sh: 卸载 Dragonfly，并清理 containerd configurer 相关资源。
- 15-deploy-karpenter.sh: 安装 Karpenter 并创建 GPU NodePool，只读取 00-prepare 已写入的镜像仓库和网络信息。
- 16-destroy-karpenter.sh: 卸载 Karpenter。
- 17-deploy-gpu-operator.sh: 安装 GPU Operator 并创建 NVIDIADriver，只读取 00-prepare 已写入的镜像仓库信息。
- 18-destroy-gpu-operator.sh: 卸载 GPU Operator。
- 99-cleanup.sh: 一键回收环境资源。

自定义 Prometheus 抓取对象会额外镜像到 `azmonitoring.coreos.com/v1` 这组 Azure Monitor 自带 CRD；只有 `monitoring.coreos.com/v1` 的 `ServiceMonitor` 或 `PodMonitor` 时，Azure Managed Prometheus 不一定会发现这些目标。

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
./01-environment/shell/20-deploy-dragonfly.sh
./01-environment/shell/15-deploy-karpenter.sh
./01-environment/shell/17-deploy-gpu-operator.sh
```

运行这个 shell 流程之前，先完成仓库顶层的共享准备步骤；01 不会帮你补镜像同步或网络创建，只会消费并校验 .generated.env / aks.env 中已有结果。

把业务镜像同步到 ACR 后，首个 workload 的实际部署就是预热过程；后续新节点仍会优先从 Dragonfly peers 拿分片，而不是每次都完整回源 ACR。

如果你要使用“on-demand 同时承担 baseline / fallback、elastic 层优先 spot、且新增 workload 节点自动加入 P2P”这套设计，当前 RTXPRO6000 / Karpenter 组合下，GPU workload 节点应保持 Ubuntu2404。仓库默认已经这样设置；不要把 GPU_NODE_IMAGE_FAMILY 改成 Ubuntu2204。

说明：10-create-aks.sh 现在会自动调用 12-deploy-cert-manager.sh，因此正常场景不需要单独执行 12；如果你只想重试证书平台安装，再单独运行 12 即可。

说明：10-create-aks.sh 也会自动调用 19-import-grafana-dashboards.sh，把 Istio workload 看板和当前仓库兼容的 GPU DCGM 看板导入到 Azure Managed Grafana；如果只想重试 dashboard 导入，可单独运行 19。

## Charts 位置

shell 流程依赖 vendored Helm charts，统一放在 01-environment/charts 下。

默认行为：10-create-aks.sh 会显式开启 AKS Azure Blob CSI Driver；如果集群已存在但该驱动未开启，脚本也会执行一次 `az aks update --enable-blob-driver` 做对齐。

同时，10-create-aks.sh 现在会默认确保以下平台能力已经就绪：

- AKS managed Istio (`asm-1-27`)
- AKS managed Gateway API
- external ingress gateway（默认关闭，可用统一开关开启）
- internal ingress gateway（默认关闭，可用统一开关开启）
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