# GPU Probe Image

这个目录只负责镜像构建与推送。

## 内容

- 20-build-test-image.sh: 通过 ACR Tasks 构建并推送镜像。
- test-app/: 构建上下文。

## 使用

```bash
cp aks.env.sample aks.env
./03-images/gpu-probe/20-build-test-image.sh
```

镜像地址会写入根目录下的 .generated.env 中，供 04 工作负载阶段复用。