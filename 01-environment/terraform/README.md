# Terraform Workflow

这一套实现参考了 terraform-infra-setup 的使用习惯：Terraform 文件平铺在目录根部，用少量 shell 脚本包裹 init、plan、apply、destroy。现在根目录 aks.env 是统一输入源，Terraform plan/destroy 会自动从它生成 tfvars。

## 资源范围

当前 Terraform 覆盖以下资源与集群内安装动作：

- Resource Group
- Azure Container Registry
- 或复用已有 Azure Container Registry
- Azure Monitor Workspace
- Log Analytics Workspace
- Managed Grafana
- Managed Grafana built-in dashboard import
- AKS 集群
- AKS Blob CSI Driver 默认开启
- AKS managed Gateway API
- AKS 托管 Istio / Azure Service Mesh add-on（可选）
- cert-manager
- Let's Encrypt staging / prod `ClusterIssuer`
- AKS 集群创建后自动应用 AMA metrics scrape ConfigMap
- AKS 托管 Istio internal / external ingress gateway HPA 配置
- Kiali（anonymous 模式）+ Azure Monitor auth proxy
- AKS 到 ACR 的 AcrPull 授权
- Managed Prometheus Data Collection Rule 与 Association
- Managed Prometheus Node / Kubernetes recording rule groups
- AKS 诊断设置
- ServiceMonitor CRD
- Shared KEDA workload identity + ClusterTriggerAuthentication for Azure Managed Prometheus
- Karpenter Managed Identity、Federated Credential、Azure RBAC
- Karpenter Helm charts、AKSNodeClass、GPU NodePool
- GPU Operator Helm chart、NVIDIADriver
- Dragonfly Helm chart、containerd configurer

## 初始化文件

复制样例并生成你自己的统一输入文件：

```bash
cd ../..
cp aks.env.sample aks.env
```

## 执行顺序

```bash
./00-init.sh dev
./01-plan.sh dev
./02-apply.sh dev

# or apply a specific plan file directly
./02-apply.sh ./dev.tfplan
```

销毁环境：

```bash
./03-destroy.sh dev
```

## 说明

- 环境名仍然作为脚本参数，用来生成同目录下的 dev.tfbackend 和 dev.auto.tfvars.json。
- 00-init.sh 现在也会从根目录 aks.env 动态调用 scripts/render-tfbackend-from-env.sh 生成最新的 dev.tfbackend。
- 运行 01-environment/terraform 之前，先执行顶层 [00-prepare/00-prepare.sh](00-prepare/00-prepare.sh)，确保共享前置条件已经准备完成并写入根目录 `.generated.env`。
- 01-environment/terraform 不会自动调用 00-prepare；它只消费已经准备好的 subnet、ACR 和共享镜像结果。缺任何一个依赖都应先回到 00-prepare 补齐，再重新 plan/apply。
- backend 至少需要在 aks.env 里提供 TFSTATE_RESOURCE_GROUP 和 TFSTATE_STORAGE_ACCOUNT；TFSTATE_CONTAINER 默认是 tfstate，TFSTATE_KEY 默认是 azure-gpu-demo/01-environment/<env-name>.tfstate。
- 现在默认只把根目录 aks.env 作为输入源；01-plan.sh 和 03-destroy.sh 每次执行都会重新调用 scripts/render-tfvars-from-env.sh 生成最新的 dev.auto.tfvars.json。
- 不再依赖或优先读取 dev.tfvar 这类静态环境文件；如果历史目录里还留着它们，也不会被这两个入口脚本使用。
- EXISTING_VNET_SUBNET_ID 现在是必填输入，来自 00-prepare 的共享输出；render 脚本会把它映射到 Terraform 的 existing_subnet_id，并在 plan 前校验这个 subnet id 在 Azure 中真实存在。
- EXISTING_ACR_ID 也是必填输入，来自 00-prepare 的共享输出；Terraform 只会读取这个已存在的 ACR，不再承担 ACR 创建职责。
- 如果启用了 Karpenter、GPU Operator 或 Kiali，render 脚本还会在 plan 前检查 00-prepare 写入的镜像仓库变量是否齐全，缺失时直接报错提示回到 00-prepare 补齐。
- Managed Grafana 管理员默认会自动解析当前 az login 用户/主体的 object id；如果需要授予额外管理员，再显式设置 grafana_admin_principal_ids。
- Managed Grafana 会自动集成 Azure Monitor Workspace，并补齐对 Monitor Workspace 的 Monitoring Data Reader / Monitoring Metrics Publisher 权限。
- Terraform 默认还会把仓库内置的 dashboard 自动导入到 Azure Managed Grafana，目前包括 Istio workload 看板和一个适配 DCGM exporter 的 GPU 看板；如果不想导入，可把 grafana_dashboard_import_enabled 设为 false。
- AKS 监控不只开启 monitor_metrics，还会创建 Managed Prometheus 的 DCR、DCRA，以及基础 recording rules。
- AKS 默认开启 Azure Blob CSI Driver，对应 az aks create/update 的 --enable-blob-driver；如果走统一的根目录 aks.env，可把 AKS_ENABLE_BLOB_DRIVER 设为 false；如果手写 tfvar，则使用 Terraform 变量 blob_driver_enabled。
- AKS 托管 Istio add-on 默认开启，并默认固定使用 asm-1-27；如果要改回由 AKS 自动选择，把 istio_revisions 设为 []。
- 默认会启用 AKS managed Gateway API，并安装 cert-manager；创建的 `letsencrypt-staging` / `letsencrypt-prod` 两个 `ClusterIssuer` 会继续保留给后续其他 workload 使用。使用前需要在根目录 `aks.env` 中设置 `CERT_MANAGER_ACME_EMAIL`。
- AKS 托管 Istio internal / external ingress gateway 默认都关闭；需要时再通过统一的 istio_internal_ingress_gateway_enabled / istio_external_ingress_gateway_enabled 开关开启。开启后，两组 gateway 的 HPA 副本范围分别由 istio_internal_ingress_gateway_min_replicas / max_replicas 和 istio_external_ingress_gateway_min_replicas / max_replicas 控制；如果想固定副本数，直接把对应 min 和 max 设成同一个值。
- AKS 托管 Istio 的 Gateway 资源选择器应分别使用 istio: aks-istio-ingressgateway-internal 和 istio: aks-istio-ingressgateway-external。
- 默认会部署 anonymous 模式的 Kiali，并通过带 workload identity 的 Azure Monitor auth proxy 访问 Managed Prometheus，无需在集群内保存 Entra client secret。
- 针对 Karpenter、GPU Operator、DCGM exporter 这类自定义指标，Terraform 安装脚本会额外下发 `azmonitoring.coreos.com/v1` 的 `ServiceMonitor` / `PodMonitor` 镜像对象，避免只有 `monitoring.coreos.com/v1` 资源时 Azure Managed Prometheus 不采集。
- Terraform apply 也会自动创建 KEDA operator 访问 Azure Managed Prometheus 所需的 shared workload identity 和 cluster-scoped ClusterTriggerAuthentication，供后续 04-workloads 下的 shell workload 直接复用。
- Terraform 现在只负责平台层和通用组件安装；业务 workload 统一留在 04-workloads 目录通过 shell 脚本部署和销毁。
- Karpenter 现在只保留两个 GPU NodePool：`gpu-spot-pool` 负责 elastic 容量，`gpu-ondemand-pool` 同时承担 baseline / fallback，并在没有 workload 时缩回 0 节点。
- workload 调度统一使用 dedicated label/taint `scheduling.azure-gpu-demo/dedicated=<gpu_node_class>`，以及标准标签 `karpenter.sh/capacity-type`；不要在业务清单里直接依赖 `gpu-role`、`spot_pool` 或 NodePool 名称。
- qwen loadtest 的 Gateway 默认使用 Azure internal LoadBalancer，并只保留 HTTP listener，避免公网暴露；内网验证仍然走完整的 Istio ingress 路径。
- Kiali 保持内部 `ClusterIP`，不额外暴露入口；需要访问时，使用 `kubectl port-forward -n aks-istio-system svc/kiali 20001:20001`，然后打开 `http://127.0.0.1:20001`。
- ASM 启用后，业务命名空间需要显式打 istio.io/rev=asm-X-Y 标签；不能使用 istio-injection=enabled。
- 这一版 Terraform 会在 apply 阶段通过本机的 az、kubectl、helm、python3 执行集群内软件安装，职责已经与 shell 版本基本对齐。
- AKS 托管 add-on（例如 cilium、KEDA、AMA metrics、托管 Istio ingress/pilot）仍由 AKS 平台管理，这部分镜像不会被本仓库覆盖到 ACR。
- 03-images/gpu-probe 默认会复用当前目录下的 `.generated-kubeconfig`，这样测试镜像可以构建到 01 创建的 ACR，测试工作负载也能直接部署到 01 创建的 AKS。
- `02-apply.sh` 在 Terraform apply 完成后会把常用输出同步到仓库根目录下的 `.generated.env`，方便后续脚本直接读取 ACR、AKS、kubeconfig 和监控相关变量。
- 如果只想保留基础 Azure 资源，不想在 Terraform 中安装 Karpenter 或 GPU Operator，可以把 gpu_operator_enabled 设为 false，或按需移除对应 null_resource。