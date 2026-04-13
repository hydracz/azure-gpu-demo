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
│   └── gpu-probe/           # 镜像构建阶段
├── 04-workloads/
│   └── gpu-probe/           # 工作负载部署阶段
├── aks.env.sample           # 全局环境变量模板
└── common.sh                # 全局 shell 公共函数
```

## 设计原则

- 01 只负责环境搭建，Terraform 与 shell 两套入口并存。
- 02 预留独立存储能力，避免后续 Blob CSI 与集群创建脚本耦合。
- 03 只负责镜像构建与推送，不再和集群部署混在一起。
- 04 只负责工作负载发布、回滚和验证。

## 当前推荐用法

如果你要保留原来的命令式流程，使用 01-environment/shell。

如果你要切到声明式基础设施流程，使用 01-environment/terraform。

如果你要构建测试镜像，使用 03-images/gpu-probe。

如果你要部署测试应用，使用 04-workloads/gpu-probe。

各阶段具体说明见各自 README。
