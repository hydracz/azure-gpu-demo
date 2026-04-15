# 00 Prepare

这一层负责所有共享前置准备，不放 AKS 本体和集群内平台安装。

## 负责范围

- 复用或创建 AKS 所需的 VNet、Subnet、NSG。
- 为 AKS Subnet 关联 NSG，并放行 TCP 80、443、8080、8443。
- 复用或创建 ACR。
- 同步 Karpenter、GPU Operator、Kiali 等共享镜像到目标 ACR。
- 提供独立的 Qwen 镜像同步脚本，把外部私有 ACR 里的现成镜像导入到目标 ACR。
- 把准备结果写入根目录 .generated.env，供后续 01-environment 和 workload 阶段直接消费。

## 使用

```bash
cp aks.env.sample aks.env
./00-prepare/00-prepare.sh
```

如果只想单独准备 Qwen 工作负载镜像，不想重复执行整套共享镜像同步，可以直接运行：

```bash
./00-prepare/10-sync-qwen-model.sh
```

## 输入约定

- 如果 aks.env 中提供 EXISTING_VNET_SUBNET_ID，就直接复用该子网。
- 如果 EXISTING_VNET_SUBNET_ID 为空，则按 NETWORK_RESOURCE_GROUP、VNET_NAME、VNET_ADDRESS_PREFIX、AKS_SUBNET_NAME、AKS_SUBNET_ADDRESS_PREFIX 创建或复用网络与 NSG。
- 如果 aks.env 中提供 EXISTING_ACR_ID，就直接复用该 ACR。
- 如果 EXISTING_ACR_ID 为空，则按 ACR_NAME 和 ACR_RESOURCE_GROUP / RESOURCE_GROUP 创建或复用 ACR。
- Qwen 镜像同步脚本读取 QWEN_LOADTEST_SOURCE_LOGIN_SERVER、QWEN_LOADTEST_SOURCE_IMAGE_REPOSITORY、QWEN_LOADTEST_SOURCE_IMAGE_TAG、QWEN_LOADTEST_TARGET_REPOSITORY，以及 QWEN_LOADTEST_SOURCE_PASSWORD。

## 输出

执行完成后，根目录 .generated.env 至少会包含这些关键结果：

- EXISTING_VNET_SUBNET_ID
- AKS_SUBNET_ID
- AKS_SUBNET_NSG_NAME
- NETWORK_RESOURCE_GROUP
- ACR_ID
- ACR_NAME
- ACR_LOGIN_SERVER
- QWEN_LOADTEST_TARGET_IMAGE（执行独立镜像同步脚本后写入）

后续 01-environment 不再创建网络，也不再负责镜像同步；运行 01 之前先完成这个准备阶段。