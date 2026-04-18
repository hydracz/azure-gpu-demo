#!/usr/bin/env python3

from __future__ import annotations

import argparse
import csv
import json
import re
from datetime import datetime, timezone
from pathlib import Path
from statistics import mean


SUMMARY_PATTERN = re.compile(
    r"summary rounds=(?P<rounds>\d+) total_requests=(?P<total_requests>\d+) ok=(?P<ok>\d+) busy=(?P<busy>\d+) fail5xx=(?P<fail5xx>\d+) other=(?P<other>\d+)"
)


def read_csv(path: Path) -> list[dict[str, str]]:
    if not path.exists():
        return []
    with path.open("r", encoding="utf-8", newline="") as handle:
        return list(csv.DictReader(handle))


def to_float(value: str) -> float | None:
    if value is None or value == "":
        return None
    try:
        return float(value)
    except ValueError:
        return None


def summarize_metric(rows: list[dict[str, str]], key: str) -> str:
    values = [value for value in (to_float(row.get(key, "")) for row in rows) if value is not None]
    if not values:
        return "n/a"
    return f"avg={mean(values):.1f}s, min={min(values):.1f}s, max={max(values):.1f}s"


def load_json(path: Path) -> dict | list | None:
    if not path.exists():
        return None
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def parse_ts(value: str | None) -> datetime | None:
    if not value:
        return None
    normalized = value.replace("Z", "+00:00")
    try:
        return datetime.fromisoformat(normalized).astimezone(timezone.utc)
    except ValueError:
        return None


def parse_stress_log(path: Path) -> dict[str, int] | None:
    if not path.exists():
        return None
    match = None
    for line in path.read_text(encoding="utf-8").splitlines():
        current = SUMMARY_PATTERN.search(line)
        if current:
            match = current
    if not match:
        return None
    return {key: int(value) for key, value in match.groupdict().items()}


def read_phase_plan(path: Path) -> list[dict[str, str]]:
    if not path.exists():
        return []
    rows: list[dict[str, str]] = []
    for line in path.read_text(encoding="utf-8").splitlines()[1:]:
        if not line.strip():
            continue
        phase, duration_seconds, concurrency, steps, cfg = line.split("\t")
        rows.append(
            {
                "phase": phase,
                "duration_seconds": duration_seconds,
                "concurrency": concurrency,
                "steps": steps,
                "cfg": cfg,
            }
        )
    return rows


def grafana_value(path: Path) -> str:
    payload = load_json(path)
    if not isinstance(payload, dict):
        return "missing"
    result = ((payload.get("data") or {}).get("result")) or []
    if not result:
        return "no data"

    sample = result[0]
    value = sample.get("value") or []
    if len(value) >= 2:
        return str(value[1])
    return "has data"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output-dir", required=True)
    args = parser.parse_args()

    output_dir = Path(args.output_dir)
    nodes = read_csv(output_dir / "nodes.csv")
    drivers = read_csv(output_dir / "driver-pods.csv")
    qwen_pods = read_csv(output_dir / "qwen-pods.csv")
    phase_plan = read_phase_plan(output_dir / "phase-plan.tsv")
    summary_json = load_json(output_dir / "summary.json") or {}
    metadata_json = load_json(output_dir / "metadata.json") or {}
    monitor_started_at = parse_ts(metadata_json.get("started_at"))

    if monitor_started_at is not None:
        qwen_pods = [
            row
            for row in qwen_pods
            if (created_ts := parse_ts(row.get("created_ts"))) is None or created_ts >= monitor_started_at
        ]

    node_capacity_counts: dict[str, int] = {}
    for row in nodes:
        key = row.get("capacity_type") or "unknown"
        node_capacity_counts[key] = node_capacity_counts.get(key, 0) + 1

    qwen_by_component: dict[str, list[dict[str, str]]] = {}
    for row in qwen_pods:
        component = row.get("component") or "unknown"
        qwen_by_component.setdefault(component, []).append(row)

    total_planned_duration = sum(int(row["duration_seconds"]) for row in phase_plan) if phase_plan else 0

    lines: list[str] = []
    lines.append("# Qwen GPU Scale Test Report")
    lines.append("")
    lines.append("## Run Metadata")
    lines.append("")
    lines.append(f"- Output directory: {output_dir}")
    lines.append(f"- Monitor started at: {metadata_json.get('started_at', 'unknown')}")
    lines.append(f"- Monitor finished at: {summary_json.get('finished_at', 'unknown')}")
    lines.append(f"- Planned staged duration: {total_planned_duration / 60:.1f} minutes")
    lines.append(f"- GPU node selector: {metadata_json.get('gpu_node_selector', 'unknown')}")
    lines.append("")

    lines.append("## Capacity Summary")
    lines.append("")
    lines.append(f"- GPU nodes seen: {summary_json.get('gpu_nodes_seen', len(nodes))}")
    lines.append(f"- GPU nodes ready: {summary_json.get('gpu_nodes_ready', 'unknown')}")
    lines.append(f"- Node capacity mix: {json.dumps(node_capacity_counts, ensure_ascii=False)}")
    lines.append(f"- Node Ready from creation: {summarize_metric(nodes, 'ready_seconds_from_creation')}")
    lines.append(f"- GPU allocatable from creation: {summarize_metric(nodes, 'gpu_allocatable_seconds_from_creation')}")
    lines.append(f"- Driver Ready from node creation: {summarize_metric(nodes, 'driver_ready_seconds_from_creation')}")
    lines.append("")

    lines.append("## Driver Pods")
    lines.append("")
    lines.append(f"- Driver pods seen: {summary_json.get('driver_pods_seen', len(drivers))}")
    lines.append(f"- Driver pods ready: {summary_json.get('driver_pods_ready', 'unknown')}")
    lines.append(f"- Driver image pull time: {summarize_metric(drivers, 'image_pull_seconds')}")
    lines.append(f"- Driver ready from creation: {summarize_metric(drivers, 'ready_seconds_from_creation')}")
    lines.append("")

    lines.append("## Qwen Pods")
    lines.append("")
    lines.append(f"- Qwen pods seen: {summary_json.get('qwen_pods_seen', len(qwen_pods))}")
    lines.append(f"- Qwen pods ready: {summary_json.get('qwen_pods_ready', 'unknown')}")
    lines.append(f"- Qwen image pull time: {summarize_metric(qwen_pods, 'image_pull_seconds')}")
    lines.append(f"- Qwen ready from creation: {summarize_metric(qwen_pods, 'ready_seconds_from_creation')}")
    lines.append(f"- Qwen ready from image pull start: {summarize_metric(qwen_pods, 'ready_seconds_from_pull_start')}")
    for component, rows in sorted(qwen_by_component.items()):
        lines.append(f"- Component {component} ready from creation: {summarize_metric(rows, 'ready_seconds_from_creation')}")
    lines.append("")

    lines.append("## Stage Results")
    lines.append("")
    if not phase_plan:
        lines.append("- No phase plan found")
    for row in phase_plan:
        phase_name = row["phase"]
        stress_summary = parse_stress_log(output_dir / f"{phase_name}-stress.log")
        if stress_summary is None:
          lines.append(f"- {phase_name}: missing stress summary")
          continue
        lines.append(
            f"- {phase_name}: duration={row['duration_seconds']}s concurrency={row['concurrency']} total_requests={stress_summary['total_requests']} ok={stress_summary['ok']} busy={stress_summary['busy']} fail5xx={stress_summary['fail5xx']} other={stress_summary['other']}"
        )
    lines.append("")

    lines.append("## Grafana and Prometheus Checks")
    lines.append("")
    lines.append(f"- Dashboard list file: {'present' if (output_dir / 'grafana-dashboards.json').exists() else 'missing'}")
    lines.append(f"- Istio requests query: {grafana_value(output_dir / 'grafana-istio-requests.json')}")
    lines.append(f"- Istio latency query: {grafana_value(output_dir / 'grafana-istio-latency.json')}")
    lines.append(f"- GPU utilization query: {grafana_value(output_dir / 'grafana-gpu-util.json')}")
    lines.append(f"- Visible GPU query: {grafana_value(output_dir / 'grafana-gpu-visible.json')}")
    lines.append("")

    report_path = output_dir / "report.md"
    report_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(report_path)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())