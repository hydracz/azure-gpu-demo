# AKS + Karpenter GPU 部署方案

在 AKS 上使用 Karpenter 管理 GPU 节点，结合 NVIDIA GPU Operator 进行 GPU 驱动生命周期管理。

## 方案特点

- GPU 资源池保留两套: `spot` (优先) + `on-demand` (兜底)
- VNet / Subnet 支持预创建，也可通过脚本模拟创建
- AKS 网络采用 `Azure CNI underlay`，Pod 直接使用 Subnet IP
- 每节点 `maxPods` 控制为 `15`，避免 underlay 模式下 subnet IP 过度消耗
- GPU SKU: `Standard_NC128lds_xl_RTXPRO6000BSE_v6` (RTX PRO 6000 BSE)

## 目录结构

```text
azure-gpu-demo/
├── aks.env.sample              # 环境变量模板
├── common.sh                   # 公共函数库
├── 05-create-network.sh        # 模拟预创建 VNet/Subnet
├── 06-destroy-network.sh       # 删除模拟创建的网络资源
├── 10-create-aks.sh            # 创建 AKS 集群及基础设施
├── 11-delete-aks.sh            # 删除 AKS 集群
├── 15-deploy-karpenter.sh      # 部署 Karpenter + GPU NodePool
├── 16-destroy-karpenter.sh     # 卸载 Karpenter
├── 17-deploy-gpu-operator.sh   # 部署 NVIDIA GPU Operator
├── 18-destroy-gpu-operator.sh  # 卸载 GPU Operator
├── 20-build-test-image.sh      # 构建 GPU 探测镜像
├── 30-deploy-test-app.sh       # 部署 GPU 测试应用
├── 31-destroy-test-app.sh      # 删除 GPU 测试应用
├── 99-cleanup.sh               # 一键清理所有资源
├── test-app/                   # GPU 探测应用源码
│   ├── app.py
│   ├── Dockerfile
│   └── requirements.txt
└── charts/                     # Helm Charts (需手动放入)
    ├── README.md
    ├── crd-servicemonitors.yaml
    ├── gpu-operator/
    ├── karpenter/
    └── karpenter-crd/
```

## 前置条件

- 已安装并登录 Azure CLI (`az login`)
- 已安装 `kubectl`、`helm`、`docker`、`python3`
- GPU Operator 镜像同步需要 `skopeo`
- 当前订阅对目标区域具备 `Standard_NC128lds_xl_RTXPRO6000BSE_v6` 的 on-demand 配额
- 如果要验证 spot，区域里还需要对应 spot 配额
- 已准备好定制版 `karpenter-provider-azure` 控制器镜像

## 准备 Helm Charts

脚本依赖以下 Helm Charts，放入 `charts/` 目录:

```bash
# 1. Karpenter CRD 和 Karpenter (从 karpenter-provider-azure 构建产物复制)
cp -r /path/to/karpenter-provider-azure/charts/karpenter-crd charts/
cp -r /path/to/karpenter-provider-azure/charts/karpenter charts/

# 2. GPU Operator
helm repo add nvidia https://helm.ngc.nvidia.com/nvidia
helm pull nvidia/gpu-operator --version v25.3.4 --untar -d charts/

# 3. ServiceMonitor CRD (可选)
# 如果已有 Prometheus Operator，可跳过
```

详细说明参见 [charts/README.md](charts/README.md)。

## 配置

```bash
cp aks.env.sample aks.env
# 编辑 aks.env，填入实际值
```

### 关键配置项

| 变量 | 说明 | 示例值 |
|------|------|--------|
| `AZ_SUBSCRIPTION_ID` | Azure 订阅 ID | `00000000-...` |
| `LOCATION` | Azure 区域 | `southeastasia` |
| `RESOURCE_GROUP` | AKS 资源组 | `rg-aks-karpenter-gpu` |
| `CLUSTER_NAME` | AKS 集群名称 | `aks-karpenter-gpu` |
| `ACR_NAME` | Container Registry 名称 | `acrkarpentergpu` |
| `VNET_SUBNET_ID` | 预创建的 subnet 资源 ID (如已有) | 留空则用 05-create-network.sh 创建 |
| `NETWORK_RESOURCE_GROUP` | 网络资源组 | `rg-aks-karpenter-gpu-network` |
| `GPU_SKU_NAME` | GPU VM SKU | `Standard_NC128lds_xl_RTXPRO6000BSE_v6` |
| `GPU_ZONES` | GPU 节点可用区 | `southeastasia-1` |
| `KARPENTER_IMAGE_REPO` | 定制 Karpenter 控制器镜像 | `quay.io/hydracz/karpenter-controller` |
| `KARPENTER_IMAGE_TAG` | Karpenter 镜像 Tag | `v20260323-dev` |
| `INSTALL_GPU_DRIVERS` | 是否自动安装 GPU 驱动 | `false` |
| `SPOT_MAX_PRICE` | Spot 最高价 (`-1`=不限制) | `-1` |
| `SYSTEM_MAX_PODS` | system pool 每节点最大 Pod 数 | `30` |
| `KARPENTER_MAX_PODS` | GPU 节点每节点最大 Pod 数 | `15` |

## 部署步骤

### 1. 准备网络

如果已有 VNet/Subnet，在 `aks.env` 中填写 `VNET_SUBNET_ID`，跳过此步。

否则运行以下脚本模拟创建:

```bash
./05-create-network.sh
```

### 2. 创建 AKS 集群

```bash
./10-create-aks.sh
```

创建内容:
- Resource Group、ACR、Azure Monitor Workspace、Log Analytics、Managed Grafana
- AKS 集群 (Azure CNI underlay，OIDC + Workload Identity + KEDA)
- 仅 system 节点池，不启用 cluster-autoscaler

### 3. 部署 Karpenter

```bash
./15-deploy-karpenter.sh
```

创建内容:
- Karpenter Managed Identity + RBAC + Federated Credential
- 安装 `karpenter-crd` + `karpenter` Helm Charts
- `AKSNodeClass/gpu` (installGPUDrivers: false, maxPods: 15)
- `gpu-spot-pool` (weight=100, 优先使用 Spot)
- `gpu-ondemand-pool` (weight=10, Spot 不可用时回退)

### 4. 部署 GPU Operator

```bash
./17-deploy-gpu-operator.sh
```

创建内容:
- NVIDIA GPU Operator (driver.enabled=false)
- NVIDIADriver CR (使用定制 vGPU 容器化驱动)
- 同步驱动镜像到 ACR

### 5. 构建测试镜像

```bash
./20-build-test-image.sh
```

### 6. 部署测试应用

```bash
./30-deploy-test-app.sh
```

## 清理

### 仅删除测试应用

```bash
./31-destroy-test-app.sh
```

### 一键清理所有资源

```bash
# 清理集群内资源 + 删除 AKS (保留 Resource Group)
./99-cleanup.sh

# 清理所有 Azure 资源 (包括 Resource Group)
DELETE_RESOURCE_GROUP=true ./99-cleanup.sh

# 清理所有资源 + 网络 Resource Group
DELETE_RESOURCE_GROUP=true DELETE_NETWORK_RESOURCE_GROUP=true ./99-cleanup.sh
```

### 分步清理

```bash
./31-destroy-test-app.sh       # 删除测试应用
./18-destroy-gpu-operator.sh   # 卸载 GPU Operator
./16-destroy-karpenter.sh      # 卸载 Karpenter
./11-delete-aks.sh             # 删除 AKS 集群
DELETE_NETWORK_RESOURCE_GROUP=true ./06-destroy-network.sh  # 删除网络
```

## 网络与 IP 规划

方案采用单个 AKS subnet:
- Node IP 和 Pod IP 都来自该 subnet (underlay 模式)
- `maxPods` 直接影响 subnet IP 消耗

当前配置:
- system pool: `SYSTEM_MAX_PODS=30`
- Karpenter GPU 节点: `KARPENTER_MAX_PODS=15`

## 关键实现细节

### GPU NodePool 不设置 limits

GPU `NodePool` 不设置 `spec.limits`。原因是某些 Azure SKU 元数据里的 GPU 数量与节点实际上报的 `nvidia.com/gpu` 不一致，容易导致 Karpenter 误判 `all available instance types exceed limits`。

### 资源池策略

| 池 | 权重 | 类型 | 说明 |
|----|------|------|------|
| `gpu-spot-pool` | 100 | Spot | 优先使用，成本更低 |
| `gpu-ondemand-pool` | 10 | On-demand | Spot 不可用时自动回退 |

### 自动缩容

两个 NodePool 均配置 `consolidationPolicy: WhenEmpty`，节点空闲 `CONSOLIDATE_AFTER` (默认 10 分钟) 后自动缩容。

## 常用运维命令

```bash
# 查看 Karpenter NodePool 和 AKSNodeClass
kubectl get nodepools,aksnodeclasses

# 查看 GPU 节点
kubectl get nodes -L karpenter.sh/nodepool,karpenter.sh/capacity-type

# 查看 NodeClaim 状态
kubectl get nodeclaims -o wide

# 查看 Karpenter 日志
kubectl -n kube-system logs -l app.kubernetes.io/name=karpenter --tail=100

# 查看 GPU Operator 状态
kubectl -n gpu-operator get pods -o wide

# 查看 NVIDIADriver 状态
kubectl get nvidiadrivers.nvidia.com -o wide

# 检查 GPU 节点 GPU 资源
kubectl describe node <gpu-node> | grep -A5 "Allocatable" | grep nvidia

# 重新应用 GPU NodePool 配置
./15-deploy-karpenter.sh
```
