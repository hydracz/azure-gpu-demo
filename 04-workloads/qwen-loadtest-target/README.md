# Qwen Loadtest Target

这个目录只负责把已经准备好的 Qwen 工作负载部署到 AKS，并通过 Kubernetes Gateway API 暴露 HTTPS 服务，再用 KEDA 直接查询 Azure Managed Prometheus 做自动扩缩容。TLS 证书由环境阶段预装的 cert-manager 和 `letsencrypt-prod` `ClusterIssuer`，通过 annotated `Gateway` 自动签发。

## 内容

- 41-deploy.sh: 创建 Deployment、Service、annotated `Gateway`、`HTTPRoute`、`DestinationRule` 和 KEDA ScaledObject，并给业务 namespace 打 AKS managed Istio revision 标签。
- 42-smoke-test.sh: 通过 Gateway API 自动生成的 gateway service 发起并发 HTTPS 请求，并输出当前 Deployment / HPA / ScaledObject / Certificate 状态。默认通过集群内 gateway service 的 `ClusterIP` 做 `/predict` 请求，避免本机到公网 LB 的网络抖动影响验证；临时 curl pod 会显式关闭 sidecar 注入。
- 43-destroy.sh: 删除本步骤创建的工作负载与网关资源，并清理 namespace 上的 Istio revision 标签。
- 44-stress-test.sh: 在集群内启动临时 curl pod，对 `/predict` 或自定义路径持续发压，并按轮输出 `200`、`429`、`5xx` 摘要，适合直接观察 KEDA 与 Karpenter 的扩缩容效果。

## 依赖

- 01 环境已经创建完成，且 `.generated.env` 中已有 `MONITOR_WORKSPACE_QUERY_ENDPOINT`、`ISTIO_REVISIONS_CSV`、`KEDA_PROMETHEUS_AUTH_NAME` 等变量。
- `aks.env` 或 `AKS_ENV_FILE` 中配置了 Qwen 镜像来源、目标仓库路径以及工作负载参数，并且已经先执行过 `00-prepare/10-sync-qwen-model.sh`，使 `.generated.env` 中存在 `QWEN_LOADTEST_TARGET_IMAGE`。
- 当前 AKS 已启用 Managed Gateway API，并且 `GatewayClass istio` 可用。
- 当前环境已经安装 cert-manager，并且 `letsencrypt-prod` `ClusterIssuer` 为 Ready。
- 环境阶段会提前创建 KEDA operator 访问 Azure Managed Prometheus 所需的 shared workload identity，并下发 cluster-scoped `ClusterTriggerAuthentication`；shell 和 Terraform 两条环境路径都已经对齐。

## 使用

```bash
cp aks.env.sample aks.env
./00-prepare/10-sync-qwen-model.sh
./04-workloads/qwen-loadtest-target/41-deploy.sh
./04-workloads/qwen-loadtest-target/42-smoke-test.sh
./04-workloads/qwen-loadtest-target/44-stress-test.sh
./04-workloads/qwen-loadtest-target/43-destroy.sh
```

如果 `QWEN_LOADTEST_HOST` 留空，部署脚本会先创建一个 HTTP `Gateway` 以拿到公网 IP，再基于这个公网 IP 自动生成一个 `sslip.io` 域名，并用 `letsencrypt-prod` 申请正式证书。若你提供自定义域名，脚本会先校验它是否解析到该 Gateway 的公网 IP，不匹配时会直接失败，避免无效申请。

部署顺序现在是先创建只暴露 HTTP 的 bootstrap `Gateway`，拿到公网地址后再切换成带 `cert-manager.io/cluster-issuer` 注解的正式 `Gateway`，等 `Certificate` Ready 后再创建业务 `HTTPRoute`。这样可以让 cert-manager 的 `gatewayHTTPRoute` solver 独占 HTTP-01 challenge 路径，不和业务路由互相冲突。

部署时会自动把业务 namespace 打上 `istio.io/rev=asm-X-Y`。这里使用的是 AKS 托管 Istio 的 revision label，不是开源 Istio 常见的 `istio-injection=enabled`。

`42-smoke-test.sh` 支持两种模式：

- `QWEN_LOADTEST_TEST_MODE=predict`：构造一个 1x1 PNG 并调用 `/predict`，更接近真实推理流量。
- `QWEN_LOADTEST_TEST_MODE=get`：对 `QWEN_LOADTEST_TEST_PATH` 发起 GET 请求，适合 `/healthz` 这类轻量探活。

默认 `QWEN_LOADTEST_TEST_VIA_CLUSTER_GATEWAY=true`，会通过当前 workload 所属 `Gateway` 自动生成的 service `ClusterIP` 加真实 `Host` 头走完整 gateway 路径。这仍然会经过 Gateway API 管理的 ingress envoy，因此适合在本机无法直接访问公网 LB 时做功能验证；并且 smoke test 不再跳过 TLS 校验，证书链异常会直接暴露出来。

默认 smoke test 并发是 `2`。在单副本最小配置下，入口可能出现一条 `200` 加一条 `503 overflow` 的结果，这表示当前 Gateway API ingress envoy 的瞬时并发保护先触发了，而不是应用容器本身异常；如果要确认基线可用性，可临时设置 `QWEN_LOADTEST_TEST_CONCURRENCY=1`。

`44-stress-test.sh` 默认跑一轮 `30` 分钟长压测，关键默认值如下：

- `QWEN_LOADTEST_STRESS_DURATION_SECONDS=1800`
- `QWEN_LOADTEST_STRESS_CONCURRENCY=8`
- `QWEN_LOADTEST_STRESS_REQUEST_TIMEOUT=1800`
- `QWEN_LOADTEST_STRESS_STEPS=20`
- `QWEN_LOADTEST_STRESS_CFG=2.5`
- `QWEN_LOADTEST_TEST_MODE=predict`
- `QWEN_LOADTEST_TEST_PATH=/predict`
- `QWEN_LOADTEST_TEST_VIA_CLUSTER_GATEWAY=true`

常见用法：

```bash
# 默认 30 分钟 /predict 长压
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

压测结束后脚本还会自动输出当前 `Deployment`、`Pod`、`Service`、`HPA` 和 `ScaledObject` 状态，便于对照 KEDA / Karpenter 是否已经把副本补齐。

KEDA 使用的缩放查询会写入根目录 `.generated.env` 中的 `QWEN_LOADTEST_KEDA_QUERY`，并通过环境阶段预创建的 `ClusterTriggerAuthentication` 直接访问 Azure Managed Prometheus。当前默认按以下指标缩放：

- `increase(istio_requests_total[5m])`

默认查询会固定到 `reporter="destination"`、`source_workload="qwen-loadtest-external"` 和 `destination_workload="qwen-loadtest-target"` 这组标签，统计最近 5 分钟内从 Gateway API ingress envoy 成功送达业务 workload 的请求增量。之所以使用 destination reporter，是因为当前 Azure Managed Prometheus 中这条链路能稳定看到业务请求，而 `envoy_cluster_upstream_rq_*` 与 ingress source reporter 侧仍然主要只暴露 `xds-grpc` 或零值序列。阈值默认是 `1`，也就是最近 5 分钟内累计 1 个成功请求就会给 KEDA 一个扩容信号。

如果你观察到该指标在 Azure Managed Prometheus 中采样不稳定，可以先保留当前配置用于环境验证，再按实际流量特征把查询调整为更适合你业务的公式。