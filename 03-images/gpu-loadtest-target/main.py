from __future__ import annotations

import os
import threading
import time

from fastapi import FastAPI, File, Form, UploadFile
from fastapi.responses import JSONResponse
import torch

app = FastAPI(title="GPU Load Test Target")
compute_lock = threading.Lock()


@app.get("/healthz")
def healthz() -> dict[str, str]:
    return {"status": "ok"}


@app.post("/predict")
def predict(
    image: UploadFile = File(...),
    prompt: str = Form(""),
    steps: int = Form(6),
    cfg: float = Form(2.5),
) -> JSONResponse:
    acquired = compute_lock.acquire(blocking=False)
    if not acquired:
        return JSONResponse(
            status_code=429,
            content={"status": "busy", "detail": "another inference is already running"},
        )

    try:
        if not torch.cuda.is_available():
            return JSONResponse(status_code=503, content={"status": "no_cuda"})

        _ = image.file.read(1024)
        size = int(os.getenv("GPU_LOADTEST_MATRIX_SIZE", "4096"))
        loops = max(1, int(steps))
        start_time = time.perf_counter()
        device = torch.device("cuda")
        left = torch.randn((size, size), device=device, dtype=torch.float16)
        right = torch.randn((size, size), device=device, dtype=torch.float16)
        result = None
        with torch.inference_mode():
            for _index in range(loops):
                result = torch.matmul(left, right)
            torch.cuda.synchronize()
        elapsed = time.perf_counter() - start_time
        checksum = float(result[0, 0].detach().float().cpu()) if result is not None else 0.0
        return JSONResponse(
            content={
                "status": "success",
                "gpu_execution_time": round(elapsed, 4),
                "received_prompt": prompt,
                "executed_steps": loops,
                "cfg": cfg,
                "checksum": round(checksum, 4),
            }
        )
    finally:
        if torch.cuda.is_available():
            torch.cuda.empty_cache()
        compute_lock.release()
