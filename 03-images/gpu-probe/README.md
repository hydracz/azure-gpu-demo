# GPU Probe Test App

这个目录统一负责 GPU probe 测试应用的镜像构建、部署和清理，并直接对接 01 环境创建的 ACR 与 AKS。

## 内容

- 20-build-test-image.sh: 通过 ACR Tasks 构建并推送镜像。
- 30-deploy-test-app.sh: 把测试应用部署到 01 环境创建的 AKS。
- 31-destroy-test-app.sh: 删除测试应用。
- test-app/: 构建上下文。

## 使用

```bash
cp aks.env.sample aks.env
./03-images/gpu-probe/20-build-test-image.sh
./03-images/gpu-probe/30-deploy-test-app.sh
./03-images/gpu-probe/31-destroy-test-app.sh
```

前提是 `aks.env` 中的 `ACR_NAME` / `RESOURCE_GROUP` / `CLUSTER_NAME` 指向 01 阶段创建的环境。

部署脚本会优先复用仓库内的 [01-environment/terraform/.generated-kubeconfig](01-environment/terraform/.generated-kubeconfig)。
如果文件不存在或内容为空，会自动通过 `az aks get-credentials` 重新写回，再用于部署和清理测试应用。

脚本会把以下信息写入根目录下的 `.generated.env`，供后续步骤直接复用：

- `TEST_IMAGE_URI`
- `TEST_IMAGE_ACR_LOGIN_SERVER`
- `TEST_IMAGE_REPOSITORY_PATH`
- `AKS_KUBECONFIG_FILE`