FROM python:3.11-slim

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    UV_LINK_MODE=copy \
    HF_HOME=/opt/model-cache \
    TRANSFORMERS_CACHE=/opt/model-cache \
    MODEL_CACHE_DIR=/opt/model-cache \
    MODEL_ID=Qwen/Qwen-Image-Edit-2511

WORKDIR /app

RUN apt-get update && \
    if [ "$(apt-cache policy libgl1-mesa-glx | awk '/Candidate:/ {print $2}')" != "(none)" ]; then \
        apt-get install -y --no-install-recommends curl git libgl1-mesa-glx libglib2.0-0; \
    else \
        apt-get install -y --no-install-recommends curl git libgl1 libglib2.0-0; \
    fi && \
    rm -rf /var/lib/apt/lists/*

RUN curl -LsSf https://astral.sh/uv/install.sh | sh
ENV PATH="/root/.local/bin:${PATH}"

RUN uv pip install --system torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu128 && \
    uv pip install --system "diffusers[torch]" transformers accelerate sentencepiece protobuf safetensors fastapi uvicorn python-multipart pillow huggingface_hub[hf_transfer]

RUN mkdir -p /opt/model-cache
RUN python -c "from diffusers import QwenImageEditPlusPipeline; import torch; QwenImageEditPlusPipeline.from_pretrained('Qwen/Qwen-Image-Edit-2511', torch_dtype=torch.bfloat16, cache_dir='/opt/model-cache')"

COPY main.py /app/main.py

EXPOSE 8080

CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8080", "--workers", "1"]
