#!/usr/bin/env bash
set -euxo pipefail

HEALTH_PATH=${HEALTH_PATH:-/home/azureuser/qwen-container-health.json}
RESULT_PATH=${RESULT_PATH:-/home/azureuser/qwen-container-predict.json}

rm -f "$HEALTH_PATH" "$RESULT_PATH"

for _ in $(seq 1 90); do
  if curl -fsS http://127.0.0.1:8080/healthz >"$HEALTH_PATH" 2>/dev/null; then
    break
  fi
  if ! docker ps --filter "name=qwen-loadtest-target" --format '{{.Names}}' | grep -q qwen-loadtest-target; then
    echo "container is not running" >&2
    docker ps -a >&2 || true
    docker logs qwen-loadtest-target >&2 || true
    exit 1
  fi
  sleep 10
done

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

dummy_path = Path("/home/azureuser/container_failfast_input.png")
rng = random.Random(42)
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

boundary = "----qwencontainersmoke"

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
    parts.append(b'Content-Disposition: form-data; name="image"; filename="container_failfast_input.png"\r\n')
    parts.append(b"Content-Type: image/png\r\n\r\n")
    parts.append(image_bytes)
    parts.append(b"\r\n")
    parts.append(f"--{boundary}--\r\n".encode())
    request = urllib.request.Request(
        "http://127.0.0.1:8080/predict",
        data=b"".join(parts),
        method="POST",
        headers={"Content-Type": f"multipart/form-data; boundary={boundary}"},
    )
    started = time.perf_counter()
    try:
        with urllib.request.urlopen(request, timeout=1800) as response:
            payload = json.loads(response.read().decode())
            return {"status_code": response.status, "elapsed": round(time.perf_counter() - started, 3), "payload": payload}
    except urllib.error.HTTPError as exc:
        payload = json.loads(exc.read().decode())
        return {"status_code": exc.code, "elapsed": round(time.perf_counter() - started, 3), "payload": payload}

results = {}

def worker(name: str, prompt: str) -> None:
    results[name] = call_api(prompt)

first = threading.Thread(target=worker, args=("first", "Turn this original city scene into a neon cyberpunk city at night."))
second = threading.Thread(target=worker, args=("second", "Turn this original city scene into a rainy noir cyberpunk city."))

first.start()
time.sleep(1)
second.start()
first.join()
second.join()

status_codes = {results["first"]["status_code"], results["second"]["status_code"]}
if status_codes != {200, 429}:
    raise SystemExit(f"unexpected status codes: {results}")

busy_result = results["first"] if results["first"]["status_code"] == 429 else results["second"]
success_result = results["first"] if results["first"]["status_code"] == 200 else results["second"]

if busy_result["payload"]["status"] != "busy":
    raise SystemExit(f"expected busy payload, got: {results}")

if success_result["payload"]["status"] != "success":
    raise SystemExit(f"expected success payload, got: {results}")

print(json.dumps(results, ensure_ascii=True))
PY

cat "$HEALTH_PATH"
cat "$RESULT_PATH"
docker logs --tail 100 qwen-loadtest-target
