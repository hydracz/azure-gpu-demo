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
├── application-qwen-a100-demo/ # Qwen A100 图生图压测应用示例
├── aks.env.sample           # 全局环境变量模板
└── common.sh                # 全局 shell 公共函数
```

## 设计原则

- 01 只负责环境搭建，Terraform 与 shell 两套入口并存。
- 02 预留独立存储能力，避免后续 Blob CSI 与集群创建脚本耦合。
- 03 负责 GPU probe 测试应用的完整验证闭环，包括镜像构建、发布和清理。
- 01 环境阶段会把常用输出写入 `.generated.env`，方便后续测试脚本直接复用。

## 当前推荐用法

如果你要保留原来的命令式流程，使用 01-environment/shell。

如果你要切到声明式基础设施流程，使用 01-environment/terraform。

如果你要构建并部署 GPU probe 测试应用，使用 03-images/gpu-probe。

如果你要运行一个重型图生图 Serverless 压测目标，使用 application-qwen-a100-demo。

各阶段具体说明见各自 README。
