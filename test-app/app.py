from __future__ import annotations

import os
import subprocess
import time
from contextlib import asynccontextmanager

from fastapi import FastAPI, Request
from fastapi.responses import PlainTextResponse
from prometheus_client import CONTENT_TYPE_LATEST, Counter, Gauge, Histogram, generate_latest


REQUEST_COUNT = Counter(
    "gpu_probe_requests_total",
    "Total request count",
    ["method", "path", "status"],
)
REQUEST_LATENCY = Histogram(
    "gpu_probe_request_duration_seconds",
    "Request latency in seconds",
    ["path"],
)
INFLIGHT_REQUESTS = Gauge(
    "gpu_probe_inflight_requests",
    "Current inflight requests",
)

# GPU detection — cached at startup
_gpu_info: dict | None = None


def _detect_gpu() -> dict:
    """Detect NVIDIA GPU via nvidia-smi. Returns a dict with detection results."""
    info: dict = {"gpu_available": False, "driver_installed": False, "details": ""}
    try:
        result = subprocess.run(
            ["nvidia-smi", "--query-gpu=name,driver_version,memory.total,gpu_uuid", "--format=csv,noheader"],
            capture_output=True, text=True, timeout=10,
        )
        if result.returncode == 0 and result.stdout.strip():
            info["gpu_available"] = True
            info["driver_installed"] = True
            info["details"] = result.stdout.strip()
        else:
            info["details"] = result.stderr.strip() or "nvidia-smi returned no output"
    except FileNotFoundError:
        info["details"] = "nvidia-smi not found (GPU driver not installed)"
    except subprocess.TimeoutExpired:
        info["details"] = "nvidia-smi timed out"
    except Exception as e:
        info["details"] = str(e)

    # Check PCI for NVIDIA devices even without driver
    try:
        result = subprocess.run(
            ["lspci"], capture_output=True, text=True, timeout=5,
        )
        if result.returncode == 0:
            nvidia_lines = [l for l in result.stdout.splitlines() if "NVIDIA" in l.upper()]
            if nvidia_lines:
                info["gpu_available"] = True
                info["pci_devices"] = nvidia_lines
    except (FileNotFoundError, subprocess.TimeoutExpired):
        pass

    return info


@asynccontextmanager
async def lifespan(_: FastAPI):
    global _gpu_info
    _gpu_info = _detect_gpu()
    yield


app = FastAPI(title="gpu-probe", version="1.0.0", lifespan=lifespan)


@app.middleware("http")
async def collect_metrics(request: Request, call_next):
    start = time.perf_counter()
    INFLIGHT_REQUESTS.inc()
    status_code = 500
    try:
        response = await call_next(request)
        status_code = response.status_code
        return response
    finally:
        duration = time.perf_counter() - start
        REQUEST_COUNT.labels(request.method, request.url.path, str(status_code)).inc()
        REQUEST_LATENCY.labels(request.url.path).observe(duration)
        INFLIGHT_REQUESTS.dec()


@app.get("/")
def root() -> dict:
    return {
        "service": "gpu-probe",
        "pod": os.getenv("POD_NAME", "unknown"),
        "node": os.getenv("NODE_NAME", "unknown"),
        "namespace": os.getenv("POD_NAMESPACE", "unknown"),
        "gpu": _gpu_info,
    }


@app.get("/healthz")
def healthz() -> dict[str, str]:
    return {"status": "ok"}


@app.get("/gpu")
def gpu_status() -> dict:
    """Return GPU detection results."""
    return {
        "pod": os.getenv("POD_NAME", "unknown"),
        "node": os.getenv("NODE_NAME", "unknown"),
        "gpu": _gpu_info,
    }


@app.get("/gpu/refresh")
def gpu_refresh() -> dict:
    """Re-run GPU detection (useful after GPU Operator installs drivers)."""
    global _gpu_info
    _gpu_info = _detect_gpu()
    return {
        "pod": os.getenv("POD_NAME", "unknown"),
        "node": os.getenv("NODE_NAME", "unknown"),
        "gpu": _gpu_info,
    }


@app.get("/node-info")
def node_info() -> dict:
    """Return node-level info visible to the Pod."""
    info = {
        "pod": os.getenv("POD_NAME", "unknown"),
        "node": os.getenv("NODE_NAME", "unknown"),
        "namespace": os.getenv("POD_NAMESPACE", "unknown"),
    }
    # CPU info
    try:
        with open("/proc/cpuinfo") as f:
            cpuinfo = f.read()
        cpu_count = cpuinfo.count("processor\t:")
        model_lines = [l for l in cpuinfo.splitlines() if l.startswith("model name")]
        info["cpu_count"] = cpu_count
        if model_lines:
            info["cpu_model"] = model_lines[0].split(":", 1)[1].strip()
    except Exception:
        pass
    # Memory info
    try:
        with open("/proc/meminfo") as f:
            meminfo = f.read()
        for line in meminfo.splitlines():
            if line.startswith("MemTotal:"):
                info["mem_total"] = line.split(":", 1)[1].strip()
                break
    except Exception:
        pass
    return info


@app.get("/metrics")
def metrics() -> PlainTextResponse:
    return PlainTextResponse(generate_latest().decode("utf-8"), media_type=CONTENT_TYPE_LATEST)
