# Blob CSI

这个目录预留给后续独立的 Blob CSI 使用流程。

建议后续继续保持分层，而不是回到把存储操作塞进 01 环境目录里。

## 推荐后续结构

```text
02-storage/blob-csi/
├── README.md
├── manifests/      # StorageClass、PV、PVC、SecretProviderClass 等 YAML
├── shell/          # 挂载验证、调试脚本
└── terraform/      # 如需创建 Storage Account、Container、RBAC，可放这里
```

## 边界建议

- 01 只负责把 AKS 集群准备好。
- 02 负责 Blob CSI 驱动启用、存储账号访问策略、挂载验证。
- 03 和 04 只消费已准备好的存储能力，不负责创建存储基础设施。