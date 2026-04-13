# GPU Probe Workload

这个目录只负责把测试工作负载部署到已经准备好的 AKS 集群。

## 内容

- 30-deploy-test-app.sh: 发布 GPU probe 工作负载。
- 31-destroy-test-app.sh: 删除 GPU probe 工作负载。

## 使用

```bash
cp aks.env.sample aks.env
./04-workloads/gpu-probe/30-deploy-test-app.sh
./04-workloads/gpu-probe/31-destroy-test-app.sh
```

前提是 01 环境阶段已经完成，并且 03 阶段已经生成 TEST_IMAGE_URI。