#!/usr/bin/env bash
set -euxo pipefail

WORKDIR=/opt/qwen-loadtest
IMAGE_TAG=${IMAGE_TAG:-qwen-loadtest-target:sea-a100}
CONTAINER_NAME=${CONTAINER_NAME:-qwen-loadtest-target}

mkdir -p "${WORKDIR}"
cd "${WORKDIR}"

pkill -f 'uvicorn main:app' || true
pkill -f '/opt/qwen-hostcheck/.venv/bin/python3 .*uvicorn' || true

docker build -t "${IMAGE_TAG}" .

docker rm -f "${CONTAINER_NAME}" || true
docker run -d \
  --name "${CONTAINER_NAME}" \
  --restart unless-stopped \
  --gpus all \
  -p 127.0.0.1:8080:8080 \
  "${IMAGE_TAG}"

docker ps --filter "name=${CONTAINER_NAME}"
