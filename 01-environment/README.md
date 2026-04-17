# 01 Environment

这一层只处理环境搭建，不放应用构建和业务工作负载。

## 子目录

- shell: 保留现有命令式流程，适合快速验证、手动排障和跟踪每一步 Azure/Kubernetes 操作。
- terraform: 新增声明式基础设施实现，适合后续标准化、参数化和多环境复用。
- charts: shell 流程依赖的 vendored Helm charts。

## 建议边界

- 这里负责 Monitor Workspace、Log Analytics、Grafana、AKS，以及集群内的 Dragonfly、Karpenter 和 GPU Operator 基础安装。
- 这里也负责把仓库内置 Grafana dashboard 导入 Azure Managed Grafana，避免环境创建后还要手工补看板。
- 这里也负责 AKS managed Gateway API、cert-manager 和 Let's Encrypt ClusterIssuer 这些平台级 TLS 基础能力，供后续 workload 直接复用。
- Blob CSI、镜像构建、应用发布等能力放到后续阶段目录，不再塞回 01。
- 共享前置准备步骤已经收口到顶层 00-prepare；01 只消费并校验已经准备好的网络、ACR 与镜像结果。