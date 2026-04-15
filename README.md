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
- 01 环境阶段会统一安装 cert-manager、Istio IngressClass 和 Let's Encrypt ClusterIssuer，后续 workload 不再各自生成自签名证书。
- 01 环境阶段也会统一把仓库内置的 Grafana dashboards 导入 Azure Managed Grafana，保证新环境创建后即可查看 Istio 与 GPU 监控面板。
- 02 预留独立存储能力，避免后续 Blob CSI 与集群创建脚本耦合。
- 03 负责 GPU probe 测试应用的完整验证闭环，包括镜像构建、发布和清理。
- 04 负责更接近真实流量入口的工作负载发布，例如外部镜像同步、Istio 网关暴露和 KEDA 自动扩缩容。
- `aks.env` 现在是整个仓库统一的手填输入入口；Terraform 参数和 shell 脚本参数都从这里派生。
- 01 环境阶段会把常用输出写入 `.generated.env`，方便后续测试脚本直接复用。

## 当前推荐用法

如果你要保留原来的命令式流程，使用 01-environment/shell。

如果你要切到声明式基础设施流程，使用 01-environment/terraform；现在不再强制手写 tfvar，plan/destroy 会从根目录 aks.env 自动生成 tfvars。

如果你要构建并部署 GPU probe 测试应用，使用 03-images/gpu-probe。

各阶段具体说明见各自 README。
