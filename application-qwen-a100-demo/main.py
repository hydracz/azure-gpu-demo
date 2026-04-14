from __future__ import annotations

import io
import os
import threading
import time
from typing import Any

from fastapi import FastAPI, File, Form, HTTPException, UploadFile
from fastapi.responses import JSONResponse
from PIL import Image, UnidentifiedImageError
import torch
from diffusers import QwenImageEditPlusPipeline


MODEL_ID = os.getenv("MODEL_ID", "Qwen/Qwen-Image-Edit-2511")
MODEL_CACHE_DIR = os.getenv("MODEL_CACHE_DIR", "/opt/model-cache")
DEVICE = os.getenv("MODEL_DEVICE", "cuda")

app = FastAPI(title="Qwen Load Test Target")
pipeline_lock = threading.Lock()
PIPELINE: QwenImageEditPlusPipeline | None = None


def _require_pipeline() -> QwenImageEditPlusPipeline:
    if PIPELINE is None:
        raise RuntimeError("Pipeline is not loaded")
    return PIPELINE


def load_pipeline() -> QwenImageEditPlusPipeline:
    if not torch.cuda.is_available():
        raise RuntimeError("CUDA is required for this service")

    loaded_pipeline = QwenImageEditPlusPipeline.from_pretrained(
        MODEL_ID,
        torch_dtype=torch.bfloat16,
        cache_dir=MODEL_CACHE_DIR,
    )
    loaded_pipeline.to(DEVICE)
    loaded_pipeline.set_progress_bar_config(disable=True)
    return loaded_pipeline


@app.on_event("startup")
def startup_event() -> None:
    global PIPELINE
    PIPELINE = load_pipeline()


@app.get("/healthz")
def healthz() -> dict[str, str]:
    return {"status": "ok"}


@app.post("/predict")
def predict(
    image: UploadFile = File(...),
    prompt: str = Form(...),
    steps: int = Form(20),
    cfg: float = Form(2.5),
) -> Any:
    acquired = pipeline_lock.acquire(blocking=False)
    if not acquired:
        return JSONResponse(
            status_code=429,
            content={
                "status": "busy",
                "detail": "another inference is already running",
                "retry_after_seconds": 2,
            },
        )

    if steps < 1:
        raise HTTPException(status_code=400, detail="steps must be >= 1")

    if cfg <= 0:
        raise HTTPException(status_code=400, detail="cfg must be > 0")

    file_bytes = image.file.read()
    if not file_bytes:
        raise HTTPException(status_code=400, detail="image is empty")

    try:
        input_image = Image.open(io.BytesIO(file_bytes)).convert("RGB")
    except UnidentifiedImageError as exc:
        raise HTTPException(status_code=400, detail="image must be a valid image file") from exc

    pipeline = _require_pipeline()
    start_time = time.perf_counter()

    try:
        with torch.inference_mode():
            pipeline(
                image=input_image,
                prompt=prompt,
                true_cfg_scale=cfg,
                negative_prompt=" ",
                num_inference_steps=steps,
                guidance_scale=1.0,
                num_images_per_prompt=1,
            )
    finally:
        if torch.cuda.is_available():
            torch.cuda.empty_cache()
        pipeline_lock.release()

    elapsed = time.perf_counter() - start_time

    return {
        "status": "success",
        "gpu_execution_time": round(elapsed, 4),
        "received_prompt": prompt,
        "executed_steps": steps,
    }
