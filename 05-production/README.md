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
- `MONITOR_WORKSPACE_QUERY_ENDPOINT`: Azure Managed Prometheus 查询入口。

## 部署内容

- seed Deployment: 固定 1 个 on-demand GPU 副本。
- elastic Deployment: 默认 0 个副本，由 KEDA 按入口请求量扩到最多 4 个。
- Service: 统一暴露 seed 和 elastic Pod。
- Gateway / HTTPRoute: 通过 internal LoadBalancer 暴露 HTTP 入口。
- DestinationRule: 使用 `LEAST_REQUEST` 和短连接队列，避免请求继续打到繁忙 Pod。
- KEDA ScaledObject: 基于 Azure Managed Prometheus 中的 Istio 请求指标扩缩容。

如果镜像来自外部私有仓库，请先在 `${APP_NAME}` namespace 中创建 image pull secret，再按需要给 Deployment 增加 `imagePullSecrets`。
