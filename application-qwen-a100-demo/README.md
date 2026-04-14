# application-qwen-a100-demo

这是一个基于 `Qwen/Qwen-Image-Edit-2511` 的重型图生图服务示例，目标不是做交互式图片回传，而是作为 Serverless 冷启动和单实例负载测试目标。

应用特性如下：

- 使用 `FastAPI + Uvicorn`
- 使用 `diffusers` 中的 `QwenImageEditPlusPipeline`
- 启动时预加载模型到 GPU
- 单实例只允许一个活跃推理
- 第二个重叠请求快速返回 `429`
- 请求输入是 `multipart/form-data`
- 响应只返回 JSON，不返回生成图片

## 目录结构

```text
application-qwen-a100-demo/
├── README.md
├── main.py
├── Dockerfile
├── .dockerignore
├── scripts/
│   ├── vm-build-run.sh
│   ├── vm-container-smoke.sh
│   └── vm-validate-failfast.sh
└── tests/
    └── test_main.py
```

各文件职责：

- `main.py`：FastAPI 应用，负责模型预加载、请求解析、推理执行和 fail-fast 并发控制。
- `Dockerfile`：构建自包含厚镜像，包含 Python 依赖和模型下载步骤。
- `scripts/vm-build-run.sh`：在 Azure GPU VM 上构建并启动容器。
- `scripts/vm-container-smoke.sh`：对容器执行并发请求验证，要求得到 `200` 和 `429` 两种结果。
- `scripts/vm-validate-failfast.sh`：在宿主机 Python 环境中验证 fail-fast 行为。
- `tests/test_main.py`：契约测试，验证接口、Docker 启动约束和脚本行为。

## 应用行为

### 1. 模型加载

服务启动时会通过 `QwenImageEditPlusPipeline.from_pretrained(...)` 全局加载模型，并将 pipeline 移动到 GPU。

### 2. 并发控制

`/predict` 是同步接口 `def predict`，通过非阻塞锁控制：

- 一个请求正在推理时，第二个重叠请求不会排队执行
- 第二个请求直接返回 `429`
- 返回体示例：

```json
{
  "status": "busy",
  "detail": "another inference is already running",
  "retry_after_seconds": 2
}
```

### 3. 输入输出契约

接口：

- `POST /predict`

请求格式：

- `multipart/form-data`

表单字段：

- `image`：输入图片文件
- `prompt`：编辑提示词
- `steps`：推理步数，默认 `20`
- `cfg`：`true_cfg_scale`，默认 `2.5`

成功响应示例：

```json
{
  "status": "success",
  "gpu_execution_time": 44.8427,
  "received_prompt": "Turn this original city scene into a neon cyberpunk city at night.",
  "executed_steps": 20
}
```

注意：

- 接口会执行真实图生图推理
- 但不会返回生成后的图片
- 也不会默认把输出图片落盘
- 这是为了避免把网络带宽和图片回传时间混入压测结果

## 本地构建与运行

### Docker 构建

```bash
docker build -t qwen-loadtest-target:local .
```

### Docker 运行

```bash
docker run --rm --gpus all -p 8080:8080 qwen-loadtest-target:local
```

### 健康检查

```bash
curl http://127.0.0.1:8080/healthz
```

预期返回：

```json
{"status":"ok"}
```

## curl 调用示例

### 单次请求

```bash
curl -X POST http://127.0.0.1:8080/predict \
  -F image=@/path/to/input.png \
  -F prompt='Turn this flower into a neon cyberpunk botanical illustration with glowing petals and cinematic lighting.' \
  -F steps=20 \
  -F cfg=2.5
```

### 说明

- 输入图片建议使用较大文件，便于触发真实负载
- 本项目在 Azure A100 验证时使用过约 `13MB` 的 PNG 输入图
- 响应只返回 JSON，不返回输出图像

## Azure A100 验证步骤

以下流程已经在 Azure `southeastasia` 区域的 Spot A100 VM 上验证过：

### 1. 宿主机验证

- 在宿主机 Python 虚拟环境中启动 `main.py`
- 等待 `/healthz` 返回 `200`
- 发起两个相隔约 1 秒的重叠请求
- 验证结果为：
  - 一个请求 `200`
  - 一个请求 `429`

### 2. 容器验证

- 构建厚镜像
- 以单 worker 启动容器
- 通过 `scripts/vm-container-smoke.sh` 发起重叠请求
- 验证结果同样为：
  - 一个请求 `200`
  - 一个请求 `429`

### 3. 大图输入验证

- 使用约 `13MB` 的 PNG 文件作为输入
- 请求成功触发真实推理
- GPU 推理时间约 45 秒量级

## 已验证结果

本项目已记录到的关键结果如下：

- Host 成功请求 `gpu_execution_time`：约 `44.8054s`
- Host 忙时拒绝请求：约 `0.032s`
- Container 成功请求 `gpu_execution_time`：约 `44.8427s`
- Container 忙时拒绝请求：约 `0.031s`
- 另一次手动请求实测 `gpu_execution_time`：约 `46.9569s`
- 验证输入图片大小：约 `13MB`

这些结果表明：

- 应用确实执行了重型图生图推理
- 单实例 fail-fast 行为符合预期
- 第二个请求不是排队，而是立即返回 `429`

## 镜像说明

该应用采用单镜像自包含方式构建，镜像中包含：

- Python 运行时
- CUDA 对应 PyTorch 依赖
- diffusers / transformers / fastapi 等依赖
- 模型缓存下载层

推送到 ACR 时建议使用类似格式：

```text
<acr-login-server>/qwen-loadtest-target:<tag>
```

例如：

```text
<acr-login-server>/qwen-loadtest-target:sea-a100-failfast-YYYYMMDD
```

## 面向 AKS/后续部署的注意事项

这个目录只覆盖应用部署侧，不覆盖 AKS 编排本身。

需要注意的应用侧事实：

- 容器内监听地址是 `0.0.0.0:8080`
- 适合由 Kubernetes Service / Ingress 暴露
- `/predict` 默认不输出图片，因此更适合作为压测目标而不是交互式图像应用
- 如果后续需要“保存输出图”或“返回输出图”，建议单独新增调试接口，不要污染压测主接口

## 测试

运行契约测试：

```bash
python -m unittest discover -s application-qwen-a100-demo/tests -p "test_*.py" -v
```

测试覆盖：

- `predict` 是否是同步函数
- 是否使用非阻塞锁做 `429` fail-fast
- Dockerfile 是否固定单 worker
- 宿主机验证脚本是否使用用户可写日志路径
- 容器验证脚本是否检查 `200 + 429`

## 脱敏说明

本目录中的文档和脚本已经脱敏：

- 不包含明文密码
- 不包含 token
- 不包含完整公网 IP
- 不包含仅对某个个人环境有效的登录凭据
