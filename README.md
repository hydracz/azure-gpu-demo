# azure-gpu-demo

这个仓库现在按阶段拆分，而不是继续把所有脚本平铺在根目录。

## 目录规划

```text
azure-gpu-demo/
├── 01-environment/          # 01 环境搭建
│   ├── README.md
│   ├── charts/              # Karpenter / GPU Operator vendored charts
│   ├── shell/               # 现有 shell 版环境搭建与运维脚本
│   └── terraform/           # 新增 Terraform 版基础设施实现
├── 02-storage/
│   └── blob-csi/            # 后续独立的 Blob CSI 使用与挂载流程
├── 03-images/
│   └── gpu-probe/           # GPU probe 测试应用：build / deploy / cleanup
├── 04-workloads/            # 更接近真实入口流量的业务工作负载
├── aks.env.sample           # 全局环境变量模板
└── common.sh                # 全局 shell 公共函数
```

## 设计原则

- 01 只负责环境搭建，Terraform 与 shell 两套入口并存。
- 01 环境阶段会统一安装 cert-manager 和 Let's Encrypt ClusterIssuer，后续 workload 不再各自生成自签名证书。
- 01 环境阶段也会统一把仓库内置的 Grafana dashboards 导入 Azure Managed Grafana，保证新环境创建后即可查看 Istio 与 GPU 监控面板。
- 02 预留独立存储能力，避免后续 Blob CSI 与集群创建脚本耦合。
- 03 负责 GPU probe 测试应用的完整验证闭环，包括镜像构建、发布和清理。
- 04 负责更接近真实流量入口的工作负载发布，例如外部镜像同步、Istio 内网网关暴露和 KEDA 自动扩缩容。
- `aks.env` 现在是整个仓库统一的手填输入入口；Terraform 参数和 shell 脚本参数都从这里派生。
- 01 环境阶段会把常用输出写入 `.generated.env`，方便后续测试脚本直接复用。

## 当前推荐用法

如果你要保留原来的命令式流程，使用 01-environment/shell。

如果你要切到声明式基础设施流程，使用 01-environment/terraform；现在不再强制手写 tfvar，plan/destroy 会从根目录 aks.env 自动生成 tfvars。

如果你要构建并部署 GPU probe 测试应用，使用 03-images/gpu-probe。

各阶段具体说明见各自 README。

## GPU NodePool 设计

当前 GPU 调度模型只保留两个 NodePool：

- `gpu-ondemand-pool`：承担 baseline 容量和最终兜底，默认可以缩到 `0`，但业务 baseline 副本会优先把它拉起。
- `gpu-spot-pool`：承担所有弹性容量，Karpenter 会优先尝试 Spot；如果 Spot 因为配额、区域可用性或临时容量原因不可用，再回退到 on-demand。

这两个 NodePool 共用同一套自定义调度语义：

- dedicated label：`scheduling.azure-gpu-demo/dedicated=gpu`
- dedicated taint：`scheduling.azure-gpu-demo/dedicated=gpu:NoSchedule`

除此之外，容量类型统一使用 Karpenter 自带标签：

- `karpenter.sh/capacity-type=on-demand`
- `karpenter.sh/capacity-type=spot`

应用部署时不要直接依赖 NodePool 名称，也不要再使用 `gpu-role`、`spot_pool` 这类自定义标签。推荐写法是：

1. 先用 dedicated taint + label 把 Pod 限定在 GPU 专用节点。
2. 再用 `karpenter.azure.com/sku-gpu-name` 约束 GPU 型号。
3. baseline 副本显式要求 `karpenter.sh/capacity-type=on-demand`。
4. elastic 副本只“偏好” `karpenter.sh/capacity-type=spot`，不要把它写成强制条件，这样 Spot 不可用时才能自然回退到 on-demand。

### baseline 副本

适合常驻 `1` 个兜底副本，保证服务冷启动不完全依赖 Spot：

```yaml
tolerations:
	- key: scheduling.azure-gpu-demo/dedicated
		operator: Equal
		value: gpu
		effect: NoSchedule
	- key: nvidia.com/gpu
		operator: Exists
		effect: NoSchedule
affinity:
	nodeAffinity:
		requiredDuringSchedulingIgnoredDuringExecution:
			nodeSelectorTerms:
				- matchExpressions:
						- key: scheduling.azure-gpu-demo/dedicated
							operator: In
							values: ["gpu"]
						- key: karpenter.azure.com/sku-gpu-name
							operator: In
							values: ["rtxpro6000-bse"]
						- key: karpenter.sh/capacity-type
							operator: In
							values: ["on-demand"]
```

### elastic 副本

适合 KEDA/HPA 管理的弹性部分，优先 Spot，失败时回退 on-demand：

```yaml
tolerations:
	- key: scheduling.azure-gpu-demo/dedicated
		operator: Equal
		value: gpu
		effect: NoSchedule
	- key: kubernetes.azure.com/scalesetpriority
		operator: Equal
		value: spot
		effect: NoSchedule
	- key: nvidia.com/gpu
		operator: Exists
		effect: NoSchedule
affinity:
	nodeAffinity:
		requiredDuringSchedulingIgnoredDuringExecution:
			nodeSelectorTerms:
				- matchExpressions:
						- key: scheduling.azure-gpu-demo/dedicated
							operator: In
							values: ["gpu"]
						- key: karpenter.azure.com/sku-gpu-name
							operator: In
							values: ["rtxpro6000-bse"]
		preferredDuringSchedulingIgnoredDuringExecution:
			- weight: 100
				preference:
					matchExpressions:
						- key: scheduling.azure-gpu-demo/dedicated
							operator: In
							values: ["gpu"]
						- key: karpenter.sh/capacity-type
							operator: In
							values: ["spot"]
```

### 跑在全部 GPU 节点的 DaemonSet

例如 Dragonfly client、containerd configurer、GPU Operator 相关组件，应该这样写：

```yaml
nodeSelector:
	scheduling.azure-gpu-demo/dedicated: gpu
tolerations:
	- key: scheduling.azure-gpu-demo/dedicated
		operator: Equal
		value: gpu
		effect: NoSchedule
	- key: kubernetes.azure.com/scalesetpriority
		operator: Equal
		value: spot
		effect: NoSchedule
	- key: nvidia.com/gpu
		operator: Exists
		effect: NoSchedule
```

### 可调参数

常用的配置入口在根目录 `aks.env`：

- `GPU_NODE_CLASS`：GPU 专用节点的 dedicated label/taint 值，默认 `gpu`。
- `GPU_SKU_NAME`：GPU SKU；脚本会基于它推导 `karpenter.azure.com/sku-gpu-name` 的默认匹配值。
- `QWEN_LOADTEST_SEED_MIN_REPLICAS` / `QWEN_LOADTEST_SEED_MAX_REPLICAS`：baseline 副本范围。
- `QWEN_LOADTEST_ELASTIC_MIN_REPLICAS` / `QWEN_LOADTEST_ELASTIC_MAX_REPLICAS`：elastic 副本范围。
- `SPOT_MAX_PRICE`：Spot 池价格上限。

如果你只是想用仓库默认行为，通常不需要改 dedicated key；直接保留 `scheduling.azure-gpu-demo/dedicated=gpu` 这套约定即可。
