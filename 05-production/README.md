# 05 Production

这是一个独立的 GPU 应用部署模板。它使用可读的 Kubernetes YAML 描述应用、Service、internal Gateway、路由规则和 KEDA 扩缩容配置，再由 `apply.sh` 通过 `envsubst` 渲染并执行 `kubectl apply`。

## 使用

1. 编辑 `production.env`，至少填写 `IMAGE_URL`。
2. 确认当前 `kubectl` 上下文已经指向目标 AKS 集群。
3. 执行部署：

```bash
./05-production/apply.sh
```

如果需要使用客户自己的配置文件：

```bash
PRODUCTION_ENV_FILE=/path/to/customer.env ./05-production/apply.sh
```

脚本会把渲染后的 YAML 写到 `.rendered/`，方便部署后检查最终内容。

## 配置

主要配置都在 `production.env`：

- `APP_NAME`: 应用名，同时作为 namespace 和资源名前缀，默认 `production-app`。
- `IMAGE_URL`: 业务镜像地址，部署前必须填写。
- `CONTAINER_COMMAND`: 容器启动命令，默认 `sleep 10000`。
- `ISTIO_REQUEST_TIMEOUT`: Istio HTTPRoute 请求总超时，默认 `120s`。
- `ISTIO_CONNECT_TIMEOUT`: Istio 上游 TCP 连接建立超时，默认 `1s`。
- `MONITOR_WORKSPACE_QUERY_ENDPOINT`: Azure Managed Prometheus 查询入口。

## 部署内容

- seed Deployment: 固定 1 个 on-demand GPU 副本。
- elastic Deployment: 默认 0 个副本，由 KEDA 按入口请求量扩到最多 4 个。
- Service: 统一暴露 seed 和 elastic Pod。
- Gateway / HTTPRoute: 通过 internal LoadBalancer 暴露 HTTP 入口，并把请求总超时设置为 `ISTIO_REQUEST_TIMEOUT`。
- DestinationRule: 使用 `LEAST_REQUEST`、`ISTIO_CONNECT_TIMEOUT` 和短连接队列，避免请求继续打到繁忙 Pod。
- KEDA ScaledObject: 基于 Azure Managed Prometheus 中的 Istio 请求指标扩缩容。

## 从单 GPU 1 并发调整到 2 并发

如果只想做最小变更，不需要改 `apply.sh`。需要同时调整三层配置：应用进程并发、Istio 上游队列、KEDA 扩缩容阈值。

### 1. 应用进程必须真的支持 2 并发

如果应用内部仍然用单槽锁或单请求队列，即使 Kubernetes/Istio/KEDA 都改成 2，第二个请求也仍会被排队或返回 `429`。现网镜像需要先支持类似下面的环境变量或等价配置：

```bash
GPU_CONCURRENCY_PER_REPLICA=2
MAX_CONCURRENT_REQUESTS_PER_GPU=2
```

可以用下面方式给现网 Deployment 注入环境变量，然后重启 Pod：

```bash
APP_NAME=production-app

kubectl -n "$APP_NAME" set env deployment/"$APP_NAME-seed" \
	GPU_CONCURRENCY_PER_REPLICA=2 \
	MAX_CONCURRENT_REQUESTS_PER_GPU=2

kubectl -n "$APP_NAME" set env deployment/"$APP_NAME-elastic" \
	GPU_CONCURRENCY_PER_REPLICA=2 \
	MAX_CONCURRENT_REQUESTS_PER_GPU=2

kubectl -n "$APP_NAME" rollout restart deployment/"$APP_NAME-seed" deployment/"$APP_NAME-elastic"
```

如果镜像不读取这些变量，需要先修改应用镜像；只改 YAML 不会改变模型服务内部并发。

### 2. Istio DestinationRule 把单 Pod pending 槽从 1 改到 2

把 `DestinationRule` 中的：

```yaml
http1MaxPendingRequests: 1
```

改成：

```yaml
http1MaxPendingRequests: 2
```

现网可以直接 patch：

```bash
APP_NAME=production-app

kubectl -n "$APP_NAME" patch destinationrule "$APP_NAME" --type='merge' -p '
{
	"spec": {
		"trafficPolicy": {
			"connectionPool": {
				"http": {
					"http1MaxPendingRequests": 2,
					"maxRequestsPerConnection": 1
				}
			}
		}
	}
}'
```

`maxRequestsPerConnection: 1` 可以先保持不变，让连接保持短生命周期。

### 3. KEDA ScaledObject 阈值同步放大

如果当前每个 Pod 目标是最近 5 分钟 `30` 个有效请求，激活阈值是 `12`，那么单 Pod 并发从 1 增到 2 后，最小同步改法是乘以 2：

```yaml
threshold: "60"
activationThreshold: "24"
```

两个 ScaledObject 都要改：

```bash
APP_NAME=production-app

kubectl -n "$APP_NAME" patch scaledobject "$APP_NAME-elastic" --type=json -p='[
	{"op":"replace","path":"/spec/triggers/0/metadata/threshold","value":"60"},
	{"op":"replace","path":"/spec/triggers/0/metadata/activationThreshold","value":"24"}
]'

kubectl -n "$APP_NAME" patch scaledobject "$APP_NAME-seed" --type=json -p='[
	{"op":"replace","path":"/spec/triggers/0/metadata/threshold","value":"60"},
	{"op":"replace","path":"/spec/triggers/0/metadata/activationThreshold","value":"24"}
]'
```

这个“乘 2”适用于你只想表达“单个 GPU Pod 可以承接 2 倍请求”的场景。对于 45s 或更长的图像生成请求，`60/24` 可能偏高，会导致扩容偏慢。更准确的做法是按真实 p95 推理耗时估算：

```text
每并发槽 5 分钟目标请求数 ~= floor(300 / p95_latency_seconds * target_utilization)
每 Pod threshold = GPU_CONCURRENCY_PER_REPLICA * 每并发槽目标请求数
```

例如 p95 约 `45s`、目标利用率 `0.75`，每并发槽目标约 `5`，2 并发时 threshold 约 `10`；p95 约 `120s` 时建议降到 `2-4`。

## GPU 利用率看板解读

GPU 看板中的 Tensor Active 面板使用 `DCGM_FI_PROF_PIPE_TENSOR_ACTIVE`，表示 Tensor Core pipe active 百分比，不等同于 `nvidia-smi` 的整体 `GPU-Util`。

在 RTX PRO 6000 vGPU/MIG profile 上，`nvidia-smi --query-gpu=utilization.gpu` 可能返回 `N/A`；这时不能用 `nvidia-smi GPU-Util` 和 Grafana 直接对齐。当前验证中，一个持续 CUDA matmul 压测可以让 `DCGM_FI_PROF_PIPE_TENSOR_ACTIVE` 达到约 `96%`，说明 DCGM/Grafana 能看到高 GPU 计算活跃度。

如果真实推理压测时 Tensor Active 长期偏低，优先检查：

- 应用是否仍然只允许 1 个请求进入模型推理；
- 请求是否太短，Prometheus scrape 间隔是否错过峰值；
- 模型瓶颈是否在 CPU、图片解码、I/O、调度、显存带宽或非 Tensor Core 算子；
- latency、5xx、429 是否随并发增加而上升；
- 显存使用是否接近上限。

从 1 并发改成 2 后，如果 Tensor Active 明显上升且 latency/error ratio 可接受，说明单 Pod 并发提升有效；如果 Tensor Active 仍低但 latency 上升，通常是模型或前处理瓶颈，不是 KEDA 阈值本身的问题。

如果镜像来自外部私有仓库，请先在 `${APP_NAME}` namespace 中创建 image pull secret，再按需要给 Deployment 增加 `imagePullSecrets`。
