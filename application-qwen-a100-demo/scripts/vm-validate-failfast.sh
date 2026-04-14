#!/usr/bin/env bash
set -euxo pipefail

LOG_PATH=${LOG_PATH:-/home/azureuser/qwen-host-service.log}
RESULT_PATH=${RESULT_PATH:-/home/azureuser/qwen-host-failfast-result.json}

cd /opt/qwen-loadtest
source /opt/qwen-hostcheck/.venv/bin/activate
docker rm -f qwen-loadtest-target >/dev/null 2>&1 || true
pkill -9 -f "uvicorn main:app" || true
pkill -9 -f "/opt/qwen-hostcheck/.venv/bin/python3 .*uvicorn" || true
rm -f "$LOG_PATH" "$RESULT_PATH"

nohup /opt/qwen-hostcheck/.venv/bin/uvicorn main:app --host 127.0.0.1 --port 8080 --workers 1 >"$LOG_PATH" 2>&1 &

for _ in $(seq 1 60); do
  if curl -fsS http://127.0.0.1:8080/healthz >/dev/null 2>/dev/null; then
    break
  fi
  sleep 5
done

if [ "$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8080/healthz || true)" != "200" ]; then
  tail -n 100 "$LOG_PATH" || true
  exit 1
fi

/opt/qwen-hostcheck/.venv/bin/python >"$RESULT_PATH" <<'PY'
import json
import os
import random
import threading
import time
import urllib.error
import urllib.request
from pathlib import Path

from PIL import Image, ImageDraw

dummy_path = Path("/tmp/failfast_input.png")
rng = random.Random(19)
size = (2048, 2048)
image = Image.new("RGB", size, (20, 28, 48))
draw = ImageDraw.Draw(image)
for _ in range(40):
    x = rng.randint(0, size[0] - 200)
    width = rng.randint(60, 220)
    height = rng.randint(200, 1500)
    y = size[1] - height
    color = (rng.randint(20, 180), rng.randint(20, 180), rng.randint(20, 180))
    draw.rectangle((x, y, x + width, size[1]), fill=color)
pixels = bytearray(os.urandom(size[0] * size[1] * 3))
noise = Image.frombytes("RGB", size, bytes(pixels))
image = Image.blend(image, noise, 0.22)
image.save(dummy_path, format="PNG", compress_level=0)

boundary = "----qwenfailfast"

def call_api(prompt: str):
    image_bytes = dummy_path.read_bytes()
    parts = []
    parts.append(f"--{boundary}\r\n".encode())
    parts.append(b'Content-Disposition: form-data; name="prompt"\r\n\r\n')
    parts.append(prompt.encode() + b"\r\n")
    parts.append(f"--{boundary}\r\n".encode())
    parts.append(b'Content-Disposition: form-data; name="steps"\r\n\r\n')
    parts.append(b"20\r\n")
    parts.append(f"--{boundary}\r\n".encode())
    parts.append(b'Content-Disposition: form-data; name="cfg"\r\n\r\n')
    parts.append(b"2.5\r\n")
    parts.append(f"--{boundary}\r\n".encode())
    parts.append(b'Content-Disposition: form-data; name="image"; filename="failfast_input.png"\r\n')
    parts.append(b"Content-Type: image/png\r\n\r\n")
    parts.append(image_bytes)
    parts.append(b"\r\n")
    parts.append(f"--{boundary}--\r\n".encode())
    body = b"".join(parts)
    req = urllib.request.Request(
        "http://127.0.0.1:8080/predict",
        data=body,
        method="POST",
        headers={"Content-Type": f"multipart/form-data; boundary={boundary}"},
    )
    started = time.perf_counter()
    try:
        with urllib.request.urlopen(req, timeout=1800) as resp:
            payload = json.loads(resp.read().decode())
            return {"status_code": resp.status, "elapsed": round(time.perf_counter() - started, 3), "payload": payload}
    except urllib.error.HTTPError as exc:
        payload = json.loads(exc.read().decode())
        return {"status_code": exc.code, "elapsed": round(time.perf_counter() - started, 3), "payload": payload}

results = {}

def worker(name: str, prompt: str):
    results[name] = call_api(prompt)

first = threading.Thread(target=worker, args=("first", "Turn this original city scene into a neon cyberpunk city at night."))
second = threading.Thread(target=worker, args=("second", "Turn this original city scene into a rainy noir cyberpunk city."))

first.start()
time.sleep(1)
second.start()
first.join()
second.join()

print(json.dumps(results, ensure_ascii=True))
PY

cat "$RESULT_PATH"
tail -n 100 "$LOG_PATH"
