# Qwen Loadtest Target

这个目录只负责把已经准备好的 Qwen 工作负载部署到 AKS，并通过 Kubernetes Gateway API 暴露 internal LoadBalancer 的 HTTP 服务，再用 KEDA 直接查询 Azure Managed Prometheus 做自动扩缩容。cert-manager 和 `ClusterIssuer` 仍由环境阶段统一安装，但当前 workload 不会在部署时申请证书。

## 内容

- 41-deploy.sh: 创建 baseline / elastic 两套 Deployment、共享 Service、internal LB `Gateway`、`HTTPRoute`、`DestinationRule` 和两套 KEDA ScaledObject，并给业务 namespace 打 AKS managed Istio revision 标签。
- 42-smoke-test.sh: 通过 Gateway API 自动生成的 gateway service 发起并发 HTTP 请求，并输出当前 Deployment / HPA / ScaledObject 状态。默认通过集群内 gateway service 的 `ClusterIP` 做 `/predict` 请求；临时 curl pod 会显式关闭 sidecar 注入。
- 43-destroy.sh: 删除本步骤创建的工作负载与网关资源，并清理 namespace 上的 Istio revision 标签。
- 44-stress-test.sh: 在集群内启动临时 curl pod，对 `/predict` 或自定义路径持续发压，并按轮输出 `200`、`429`、`5xx` 摘要，适合直接观察 KEDA 与 Karpenter 的扩缩容效果。
- 45-ramp-test.sh: 运行至少 50 分钟的分阶段压测，支持先启动观测器再部署 workload，并为每个阶段保存压力日志、HPA/ScaledObject 描述和资源快照。
- 46-verify-grafana.sh: 校验 Azure Managed Grafana 是否已导入看板，并直接查询 Azure Managed Prometheus，确认 Istio 与 GPU 面板背后的关键指标有数据。
- 47-generate-report.sh: 基于分阶段压测输出自动汇总节点 Ready、NVIDIA driver Ready、镜像拉取、Pod Ready 和各阶段请求统计，生成独立 Markdown 报告。

## 依赖

- 01 环境已经创建完成，且 `.generated.env` 中已有 `MONITOR_WORKSPACE_QUERY_ENDPOINT`、`ISTIO_REVISIONS_CSV`、`KEDA_PROMETHEUS_AUTH_NAME` 等变量。
- `aks.env` 或 `AKS_ENV_FILE` 中配置了 Qwen 镜像来源、目标仓库路径以及工作负载参数，并且已经先执行过 `00-prepare/10-sync-qwen-model.sh`，使 `.generated.env` 中存在 `QWEN_LOADTEST_TARGET_IMAGE`。
- 当前 AKS 已启用 Managed Gateway API，并且 `GatewayClass istio` 可用。
- 当前环境已经安装 cert-manager 和 `ClusterIssuer`；虽然这个 workload 默认不申请证书，但环境能力仍然保留。
- 环境阶段会提前创建 KEDA operator 访问 Azure Managed Prometheus 所需的 shared workload identity，并下发 cluster-scoped `ClusterTriggerAuthentication`；shell 和 Terraform 两条环境路径都已经对齐。

## 使用

```bash
cp aks.env.sample aks.env
./00-prepare/10-sync-qwen-model.sh
./04-workloads/qwen-loadtest-target/41-deploy.sh
./04-workloads/qwen-loadtest-target/42-smoke-test.sh
./04-workloads/qwen-loadtest-target/44-stress-test.sh
QWEN_SCALE_TEST_DEPLOY_FIRST=true ./04-workloads/qwen-loadtest-target/45-ramp-test.sh
./04-workloads/qwen-loadtest-target/46-verify-grafana.sh
QWEN_SCALE_TEST_OUTPUT_DIR="$PWD/test-results/qwen-scale/<run-id>" ./04-workloads/qwen-loadtest-target/47-generate-report.sh
./04-workloads/qwen-loadtest-target/43-destroy.sh
```

如果 `QWEN_LOADTEST_HOST` 留空，部署脚本会默认使用 `qwen-loadtest-target.internal` 作为 `Host` 头，并创建 internal LB Gateway。这个 host 主要用于 Gateway 路由匹配和测试脚本里的 `--resolve`，不要求你提前配置公网 DNS。

Gateway 现在只保留 HTTP listener，并带 `service.beta.kubernetes.io/azure-load-balancer-internal: "true"` 注解，让 Azure 为这个 envoy service 分配内网 IP，而不是公网 IP。

部署时会自动把业务 namespace 打上 `istio.io/rev=asm-X-Y`。这里使用的是 AKS 托管 Istio 的 revision label，不是开源 Istio 常见的 `istio-injection=enabled`。

`42-smoke-test.sh` 支持两种模式：

- `QWEN_LOADTEST_TEST_MODE=predict`：构造一个 1x1 PNG 并调用 `/predict`，更接近真实推理流量。
- `QWEN_LOADTEST_TEST_MODE=get`：对 `QWEN_LOADTEST_TEST_PATH` 发起 GET 请求，适合 `/healthz` 这类轻量探活。

默认 `QWEN_LOADTEST_TEST_VIA_CLUSTER_GATEWAY=true`，会通过当前 workload 所属 `Gateway` 自动生成的 service `ClusterIP` 加真实 `Host` 头走完整 gateway 路径。这仍然会经过 Gateway API 管理的 ingress envoy，因此适合做稳定的内网功能验证。

如果当前环境启用了 Dragonfly，这个 workload 的首次实际部署也会自然承担大镜像预热。

默认 smoke test 并发是 `1`，会优先给出一个稳定的基线成功结果；如果你想刻意验证入口瞬时并发保护，再把 `QWEN_LOADTEST_TEST_CONCURRENCY` 提到 `2`。`predict` 模式默认使用 `QWEN_LOADTEST_TEST_STEPS=6` 和 `QWEN_LOADTEST_TEST_CFG=2.5`，这样既能覆盖真实推理路径，又不会把一次 smoke 拉得过长。

`42-smoke-test.sh` 和 `44-stress-test.sh` 现在都会在执行前刷新 live Gateway IP，并重写根目录 `.generated.env` 中的 `QWEN_LOADTEST_GATEWAY_IP`、`QWEN_LOADTEST_HOST`、`QWEN_LOADTEST_URL`，因此不再依赖旧的 ingress IP 缓存。

`44-stress-test.sh` 默认跑一轮 `15` 分钟扩容压测，关键默认值如下：

- `QWEN_LOADTEST_STRESS_DURATION_SECONDS=900`
- `QWEN_LOADTEST_STRESS_CONCURRENCY=4`
- `QWEN_LOADTEST_STRESS_REQUEST_TIMEOUT=900`
- `QWEN_LOADTEST_STRESS_STEPS=6`
- `QWEN_LOADTEST_STRESS_CFG=2.5`
- `QWEN_LOADTEST_TEST_MODE=predict`
- `QWEN_LOADTEST_TEST_PATH=/predict`
- `QWEN_LOADTEST_TEST_VIA_CLUSTER_GATEWAY=true`

如果你要调优 KEDA / HPA 行为，当前可直接通过环境变量覆盖的关键项有：

- `QWEN_LOADTEST_POLLING_INTERVAL`
- `QWEN_LOADTEST_COOLDOWN_PERIOD`
- `QWEN_LOADTEST_KEDA_QUERY_WINDOW`
- `QWEN_LOADTEST_KEDA_THRESHOLD`
- `QWEN_LOADTEST_KEDA_ACTIVATION_THRESHOLD`
- `QWEN_LOADTEST_ELASTIC_SCALEUP_PODS`
- `QWEN_LOADTEST_ELASTIC_SCALEUP_PERIOD_SECONDS`
- `QWEN_LOADTEST_ELASTIC_SCALEDOWN_STABILIZATION_SECONDS`
- `QWEN_LOADTEST_ELASTIC_SCALEDOWN_PERCENT`
- `QWEN_LOADTEST_ELASTIC_SCALEDOWN_PERIOD_SECONDS`
- `QWEN_LOADTEST_SEED_SCALEUP_PODS`
- `QWEN_LOADTEST_SEED_SCALEUP_PERIOD_SECONDS`
- `QWEN_LOADTEST_SEED_SCALEDOWN_STABILIZATION_SECONDS`
- `QWEN_LOADTEST_SEED_SCALEDOWN_PERCENT`
- `QWEN_LOADTEST_SEED_SCALEDOWN_PERIOD_SECONDS`
- `QWEN_LOADTEST_SEED_QUERY_OFFSET`

`45-ramp-test.sh` 默认使用下面这组分阶段配置，总时长 `3000` 秒，也就是 `50` 分钟：

- `warmup:300:1:6:2.5`
- `ramp1:600:2:6:2.5`
- `ramp2:600:4:6:2.5`
- `ramp3:600:6:6:2.5`
- `ramp4:900:9:6:2.5`

格式是 `阶段名:持续秒数:并发数:steps:cfg`，可以通过 `QWEN_SCALE_TEST_PHASES` 整体覆盖。默认输出目录是 `test-results/qwen-scale/<UTC时间戳>`。

如果你要从空平台开始记录完整的扩容时间线，推荐下面这个顺序：

- 先用 Terraform 只重建平台
- 然后执行 `QWEN_SCALE_TEST_DEPLOY_FIRST=true ./04-workloads/qwen-loadtest-target/45-ramp-test.sh`
- 压测结束后执行 `./04-workloads/qwen-loadtest-target/46-verify-grafana.sh`
- 最后执行 `QWEN_SCALE_TEST_OUTPUT_DIR=<本次输出目录> ./04-workloads/qwen-loadtest-target/47-generate-report.sh`

这样会把下面这些结果都留在同一个输出目录：

- `nodes.csv` / `driver-pods.csv` / `qwen-pods.csv`
- 每个阶段的 `*-stress.log`、`*-resources.txt`、`*-scaledobject.txt`
- Grafana / Prometheus 校验 JSON
- 最终的 `report.md`

当前职责边界是：Terraform 只负责平台和通用组件，例如 Dragonfly、KEDA 访问 Azure Managed Prometheus 的 shared identity，以及 AKS 相关基础设施；Qwen workload 本身始终通过本目录下的 shell 脚本部署。

常见用法：

```bash
# 默认 15 分钟 /predict 扩容压测
./04-workloads/qwen-loadtest-target/44-stress-test.sh

# 压 10 分钟，并发 4
QWEN_LOADTEST_STRESS_DURATION_SECONDS=600 \
QWEN_LOADTEST_STRESS_CONCURRENCY=4 \
./04-workloads/qwen-loadtest-target/44-stress-test.sh

# 用 /healthz 做轻量链路验证
QWEN_LOADTEST_TEST_MODE=get \
QWEN_LOADTEST_TEST_PATH=/healthz \
QWEN_LOADTEST_STRESS_DURATION_SECONDS=60 \
./04-workloads/qwen-loadtest-target/44-stress-test.sh
```

脚本会在每一轮输出类似以下摘要，方便直接看扩容过程中的行为：

```text
ts=2026-04-16T11:24:56+0800 round=39 ok=6 busy=0 fail5xx=2 other=0 slowest=29.754s
```

压测结束后脚本还会自动输出当前 `Deployment`、`Pod`、`Service`、`HPA` 和 `ScaledObject` 状态，便于对照 KEDA / Karpenter 是否已经把副本补齐。基于当前集群的实际表现，`900s / 4 并发 / steps=6` 更适合作为默认的“观察扩容行为”配置；如果要打更重的压测，再显式把并发或 `steps` 往上提。

KEDA 使用的缩放查询会写入根目录 `.generated.env` 中的 `QWEN_LOADTEST_KEDA_QUERY`、`QWEN_LOADTEST_ELASTIC_KEDA_QUERY` 和 `QWEN_LOADTEST_SEED_KEDA_QUERY`，并通过环境阶段预创建的 `ClusterTriggerAuthentication` 直接访问 Azure Managed Prometheus。当前默认按以下方式缩放：

- `increase(istio_requests_total[5m])`

当前默认缩放策略已经按冷启动 GPU 场景收敛为更保守的配置：

- baseline 层：默认 `1` 到 `2` 个副本，强制调度到 on-demand。
- elastic 层：默认 `0` 到 `4` 个副本，优先调度到 spot；如果 spot 不可用，会回退到 on-demand。
- 统一阈值：默认 `threshold=30`，`activationThreshold=12`，保留 5 分钟请求窗口，但不再对单个成功请求立刻触发扩容。
- 扩容节奏：elastic 默认每 `60` 秒最多加 `1` 个；seed 默认每 `180` 秒最多加 `1` 个。
- 缩容节奏：默认 `cooldownPeriod=600`，seed/elastic 的 scale down stabilization 默认都是 `600` 秒，并把单次缩容限制为每轮最多 `50%`。
- 顺序扩容：seed 查询默认会先扣掉 `threshold × elastic_max_replicas`，也就是先让 elastic 吃满，再允许 seed 从 baseline `1` 往上扩。

默认查询会固定到 `reporter="destination"`、`source_workload="qwen-loadtest-internal"` 和 `destination_service_name="qwen-loadtest-target"` 这组标签，统计最近 5 分钟内从 Gateway API ingress envoy 成功送达业务 service 的请求增量。之所以使用 destination reporter，是因为当前 Azure Managed Prometheus 中这条链路能稳定看到业务请求，而 `envoy_cluster_upstream_rq_*` 与 ingress source reporter 侧仍然主要只暴露 `xds-grpc` 或零值序列。当前默认阈值已经从过去的 `1` 提高到 `30`，activation threshold 默认 `12`，目的是避免冷 GPU 节点和长镜像拉取阶段被瞬时小流量过度放大。

如果你观察到该指标在 Azure Managed Prometheus 中采样不稳定，可以先保留当前配置用于环境验证，再按实际流量特征把查询调整为更适合你业务的公式。