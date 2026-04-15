# Qwen Loadtest Target

这个目录负责把外部私有镜像同步到当前环境自己的 ACR，然后把工作负载部署到 AKS，并通过托管 Istio external gateway 暴露 HTTPS 服务，再用 KEDA 直接查询 Azure Managed Prometheus 做自动扩缩容。

## 内容

- 40-sync-image.sh: 从外部私有 ACR 同步业务镜像到当前环境自己的 ACR。
- 41-deploy.sh: 创建 Deployment、Service、Istio Gateway / VirtualService 和 KEDA ScaledObject，并给业务 namespace 打 AKS managed Istio revision 标签。
- 42-smoke-test.sh: 通过 external gateway 发起并发 HTTPS 请求，并输出当前 Deployment / HPA / ScaledObject 状态。默认通过集群内的 external ingress service 做 `/predict` 请求，避免本机到公网 LB 的网络抖动影响验证；临时 curl pod 会显式关闭 sidecar 注入。
- 43-destroy.sh: 删除本步骤创建的工作负载与网关资源，并清理 namespace 上的 Istio revision 标签。

## 依赖

- 01 环境已经创建完成，且 `.generated.env` 中已有 `MONITOR_WORKSPACE_QUERY_ENDPOINT`、`ISTIO_REVISIONS_CSV`、`KEDA_PROMETHEUS_AUTH_NAME` 等变量。
- `aks.env` 或 `AKS_ENV_FILE` 中配置了 Qwen 镜像来源、目标仓库路径以及工作负载参数。
- 当前 AKS 已安装 KEDA，并且托管 Istio external ingress 已启用。
- 环境阶段会提前创建 KEDA operator 访问 Azure Managed Prometheus 所需的 shared workload identity，并下发 cluster-scoped `ClusterTriggerAuthentication`；shell 和 Terraform 两条环境路径都已经对齐。

## 使用

```bash
cp aks.env.sample aks.env
./04-workloads/qwen-loadtest-target/40-sync-image.sh
./04-workloads/qwen-loadtest-target/41-deploy.sh
./04-workloads/qwen-loadtest-target/42-smoke-test.sh
./04-workloads/qwen-loadtest-target/43-destroy.sh
```

如果 `QWEN_LOADTEST_HOST` 留空，部署脚本会基于 external ingress 的公网 IP 自动生成一个 `sslip.io` 域名，并生成自签名 TLS 证书。访问时可先用 `curl -k` 或浏览器忽略证书告警进行验证。

部署时会自动把业务 namespace 打上 `istio.io/rev=asm-X-Y`。这里使用的是 AKS 托管 Istio 的 revision label，不是开源 Istio 常见的 `istio-injection=enabled`。

`42-smoke-test.sh` 支持两种模式：

- `QWEN_LOADTEST_TEST_MODE=predict`：构造一个 1x1 PNG 并调用 `/predict`，更接近真实推理流量。
- `QWEN_LOADTEST_TEST_MODE=get`：对 `QWEN_LOADTEST_TEST_PATH` 发起 GET 请求，适合 `/healthz` 这类轻量探活。

默认 `QWEN_LOADTEST_TEST_VIA_CLUSTER_GATEWAY=true`，会通过 `aks-istio-ingressgateway-external` 的 `ClusterIP` 加真实 `Host` 头走完整 gateway 路径。这仍然会经过 external ingress envoy，因此适合在本机无法直接访问公网 LB 时做功能验证。

默认 smoke test 并发是 `2`。在单副本最小配置下，入口可能出现一条 `200` 加一条 `503 overflow` 的结果，这表示 external ingress 的瞬时并发保护先触发了，而不是应用容器本身异常；如果要确认基线可用性，可临时设置 `QWEN_LOADTEST_TEST_CONCURRENCY=1`。

KEDA 使用的缩放查询会写入根目录 `.generated.env` 中的 `QWEN_LOADTEST_KEDA_QUERY`，并通过环境阶段预创建的 `ClusterTriggerAuthentication` 直接访问 Azure Managed Prometheus。当前默认按以下指标缩放：

- `envoy_cluster_upstream_rq_active`

这个指标代表 external ingress gateway 当前转发到该 service 的活跃上游请求数。阈值默认是 `1`，也就是期望每个活跃请求对应一个 pod。

如果你观察到该指标在 Azure Managed Prometheus 中采样不稳定，可以先保留当前配置用于环境验证，再按实际流量特征把查询调整为更适合你业务的公式。