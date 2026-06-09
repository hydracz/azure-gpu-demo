# GPU Load Test Target

Lightweight FastAPI target for validating AKS GPU node provisioning, DCGM metrics, Istio traffic, KEDA scaling, and Grafana dashboards without building the full Qwen model image.

It exposes the same `/healthz` and `/predict` endpoints expected by the qwen load-test scripts. `/predict` requests a GPU and runs CUDA matrix multiplication with fail-fast 429 behavior when concurrent requests overlap.
