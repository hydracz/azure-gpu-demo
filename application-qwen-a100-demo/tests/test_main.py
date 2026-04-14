from __future__ import annotations

import ast
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
MAIN_FILE = ROOT / "main.py"
DOCKERFILE = ROOT / "Dockerfile"
README_FILE = ROOT / "README.md"
FAILFAST_SCRIPT = ROOT / "scripts" / "vm-validate-failfast.sh"
CONTAINER_SMOKE_SCRIPT = ROOT / "scripts" / "vm-container-smoke.sh"


class DemoContractTests(unittest.TestCase):
    def test_required_files_exist(self) -> None:
        self.assertTrue(MAIN_FILE.exists(), "main.py should exist")
        self.assertTrue(DOCKERFILE.exists(), "Dockerfile should exist")
        self.assertTrue(README_FILE.exists(), "README.md should exist")

    def test_predict_is_sync_and_failfast(self) -> None:
        source = MAIN_FILE.read_text(encoding="utf-8")
        tree = ast.parse(source)

        predict_node = None
        for node in tree.body:
            if isinstance(node, ast.FunctionDef) and node.name == "predict":
                predict_node = node
                break

        self.assertIsNotNone(predict_node, "predict should exist")
        self.assertIsInstance(predict_node, ast.FunctionDef, "predict must be sync def")
        self.assertIn("pipeline_lock.acquire(blocking=False)", source)
        self.assertIn("status_code=429", source)
        self.assertIn("torch.inference_mode()", source)
        self.assertIn("torch.cuda.empty_cache()", source)

    def test_dockerfile_keeps_single_worker_shape(self) -> None:
        content = DOCKERFILE.read_text(encoding="utf-8")
        self.assertIn("FROM python:3.11-slim", content)
        self.assertIn("uv pip install --system torch", content)
        self.assertIn("--workers\", \"1\"", content)
        self.assertNotIn("--limit-concurrency\", \"1\"", content)

    def test_readme_mentions_request_contract(self) -> None:
        content = README_FILE.read_text(encoding="utf-8")
        self.assertIn("429", content)
        self.assertIn("multipart/form-data", content)
        self.assertIn("/predict", content)

    def test_failfast_validation_script_uses_user_owned_logs(self) -> None:
        content = FAILFAST_SCRIPT.read_text(encoding="utf-8")
        self.assertIn("LOG_PATH=", content)
        self.assertIn("/opt/qwen-hostcheck/.venv/bin/python >\"$RESULT_PATH\" <<'PY'", content)
        self.assertNotIn("/tmp/qwen-host-service.log", content)

    def test_container_smoke_script_checks_200_and_429(self) -> None:
        content = CONTAINER_SMOKE_SCRIPT.read_text(encoding="utf-8")
        self.assertIn("threading.Thread", content)
        self.assertIn("urllib.error.HTTPError", content)
        self.assertIn('status_codes != {200, 429}', content)
        self.assertIn('busy_result["payload"]["status"] != "busy"', content)


if __name__ == "__main__":
    unittest.main()
