#!/usr/bin/env python3

from __future__ import annotations

import argparse
import csv
import json
import signal
import subprocess
import sys
import time
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


STOP = False


def on_signal(signum: int, frame: Any) -> None:
    del signum, frame
    global STOP
    STOP = True


signal.signal(signal.SIGINT, on_signal)
signal.signal(signal.SIGTERM, on_signal)


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def parse_ts(value: str | None) -> datetime | None:
    if not value:
        return None
    normalized = value.replace("Z", "+00:00")
    try:
        return datetime.fromisoformat(normalized)
    except ValueError:
        return None


def iso_or_empty(value: datetime | None) -> str:
    if value is None:
        return ""
    return value.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")


def seconds_between(start: datetime | None, end: datetime | None) -> str:
    if start is None or end is None:
        return ""
    return f"{(end - start).total_seconds():.1f}"


def run_json(command: list[str]) -> dict[str, Any] | None:
    try:
        completed = subprocess.run(
            command,
            check=True,
            capture_output=True,
            text=True,
        )
    except subprocess.CalledProcessError:
        return None

    payload = completed.stdout.strip()
    if not payload:
        return None
    try:
        return json.loads(payload)
    except json.JSONDecodeError:
        return None


def best_event_ts(item: dict[str, Any]) -> datetime | None:
    for candidate in (
        item.get("eventTime"),
        (item.get("series") or {}).get("lastObservedTime"),
        item.get("lastTimestamp"),
        item.get("firstTimestamp"),
        (item.get("metadata") or {}).get("creationTimestamp"),
    ):
        parsed = parse_ts(candidate)
        if parsed is not None:
            return parsed
    return None


def condition_transition(obj: dict[str, Any], condition_type: str, expected: str = "True") -> datetime | None:
    for condition in ((obj.get("status") or {}).get("conditions") or []):
        if condition.get("type") == condition_type and condition.get("status") == expected:
            return parse_ts(condition.get("lastTransitionTime"))
    return None


def ensure_parent(path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)


def write_json(path: Path, payload: Any) -> None:
    ensure_parent(path)
    path.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")


def update_event_fields(target: dict[str, Any], event_items: list[dict[str, Any]]) -> None:
    event_map: dict[str, dict[str, datetime]] = defaultdict(dict)

    for item in event_items:
        involved = item.get("involvedObject") or {}
        uid = involved.get("uid")
        reason = item.get("reason")
        if not uid or not reason:
            continue

        record = target.get(uid)
        if record is None:
            continue

        message = item.get("message") or ""
        container_name = record.get("container_name") or ""
        image = record.get("image") or ""

        if reason in {"Pulling", "Pulled"} and image and image not in message:
            continue
        if reason in {"Created", "Started"} and container_name and container_name not in message:
            continue

        event_ts = best_event_ts(item)
        if event_ts is None:
            continue

        current = event_map[uid].get(reason)
        if current is None or event_ts < current:
            event_map[uid][reason] = event_ts

    for uid, record in target.items():
        reasons = event_map.get(uid, {})
        if "Pulling" in reasons and record.get("pulling_ts") is None:
            record["pulling_ts"] = reasons["Pulling"]
        if "Pulled" in reasons and record.get("pulled_ts") is None:
            record["pulled_ts"] = reasons["Pulled"]
        if "Scheduled" in reasons and record.get("scheduled_event_ts") is None:
            record["scheduled_event_ts"] = reasons["Scheduled"]
        if "Started" in reasons and record.get("started_event_ts") is None:
            record["started_event_ts"] = reasons["Started"]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output-dir", required=True)
    parser.add_argument("--poll-interval", type=int, default=15)
    parser.add_argument("--gpu-node-selector", default="scheduling.azure-gpu-demo/dedicated=gpu")
    parser.add_argument("--qwen-namespace", default="qwen-loadtest")
    parser.add_argument("--qwen-label-selector", default="app=qwen-loadtest-target")
    parser.add_argument("--gpu-operator-namespace", default="gpu-operator")
    parser.add_argument("--driver-pod-prefixes", default="nvidia-vgpu-driver,nvidia-driver-daemonset")
    args = parser.parse_args()

    driver_pod_prefixes = tuple(
        prefix.strip()
        for prefix in args.driver_pod_prefixes.split(",")
        if prefix.strip()
    )

    output_dir = Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)

    nodes: dict[str, dict[str, Any]] = {}
    driver_pods: dict[str, dict[str, Any]] = {}
    qwen_pods: dict[str, dict[str, Any]] = {}
    snapshots: list[dict[str, Any]] = []

    metadata = {
        "started_at": utc_now(),
        "gpu_node_selector": args.gpu_node_selector,
        "qwen_namespace": args.qwen_namespace,
        "qwen_label_selector": args.qwen_label_selector,
        "gpu_operator_namespace": args.gpu_operator_namespace,
        "driver_pod_prefixes": list(driver_pod_prefixes),
        "poll_interval_seconds": args.poll_interval,
    }
    write_json(output_dir / "metadata.json", metadata)

    while not STOP:
        polled_at = datetime.now(timezone.utc)

        node_payload = run_json([
            "kubectl",
            "get",
            "nodes",
            "-l",
            args.gpu_node_selector,
            "-o",
            "json",
        ]) or {"items": []}

        qwen_pod_payload = run_json([
            "kubectl",
            "get",
            "pods",
            "-n",
            args.qwen_namespace,
            "-l",
            args.qwen_label_selector,
            "-o",
            "json",
        ]) or {"items": []}

        gpu_operator_payload = run_json([
            "kubectl",
            "get",
            "pods",
            "-n",
            args.gpu_operator_namespace,
            "-o",
            "json",
        ]) or {"items": []}

        qwen_events_payload = run_json([
            "kubectl",
            "get",
            "events",
            "-n",
            args.qwen_namespace,
            "-o",
            "json",
        ]) or {"items": []}

        gpu_operator_events_payload = run_json([
            "kubectl",
            "get",
            "events",
            "-n",
            args.gpu_operator_namespace,
            "-o",
            "json",
        ]) or {"items": []}

        hpa_payload = run_json([
            "kubectl",
            "get",
            "hpa",
            "-n",
            args.qwen_namespace,
            "-o",
            "json",
        ]) or {"items": []}

        scaledobject_payload = run_json([
            "kubectl",
            "get",
            "scaledobject",
            "-n",
            args.qwen_namespace,
            "-o",
            "json",
        ]) or {"items": []}

        for item in node_payload.get("items", []):
            name = (item.get("metadata") or {}).get("name")
            if not name:
                continue

            record = nodes.setdefault(
                name,
                {
                    "name": name,
                    "created_ts": parse_ts((item.get("metadata") or {}).get("creationTimestamp")),
                    "first_seen_ts": polled_at,
                    "capacity_type": (item.get("metadata") or {}).get("labels", {}).get("karpenter.sh/capacity-type", ""),
                    "ready_ts": None,
                    "gpu_allocatable_ts": None,
                    "driver_ready_ts": None,
                    "driver_pod_name": "",
                },
            )

            if record.get("ready_ts") is None:
                record["ready_ts"] = condition_transition(item, "Ready")

            allocatable_gpu = ((item.get("status") or {}).get("allocatable") or {}).get("nvidia.com/gpu")
            if allocatable_gpu and record.get("gpu_allocatable_ts") is None:
                record["gpu_allocatable_ts"] = polled_at

        for item in gpu_operator_payload.get("items", []):
            metadata_obj = item.get("metadata") or {}
            status_obj = item.get("status") or {}
            name = metadata_obj.get("name")
            uid = metadata_obj.get("uid")
            if not name or not uid or not name.startswith(driver_pod_prefixes):
                continue

            node_name = (item.get("spec") or {}).get("nodeName", "")
            ready_ts = condition_transition(item, "Ready")

            record = driver_pods.setdefault(
                uid,
                {
                    "uid": uid,
                    "name": name,
                    "node_name": node_name,
                    "container_name": next(
                        (
                            container.get("name", "")
                            for container in ((item.get("spec") or {}).get("containers") or [])
                        ),
                        "",
                    ),
                    "image": next(
                        (
                            container.get("image", "")
                            for container in ((item.get("spec") or {}).get("containers") or [])
                        ),
                        "",
                    ),
                    "created_ts": parse_ts(metadata_obj.get("creationTimestamp")),
                    "first_seen_ts": polled_at,
                    "ready_ts": ready_ts,
                    "phase": status_obj.get("phase", ""),
                    "pulling_ts": None,
                    "pulled_ts": None,
                },
            )

            if record.get("ready_ts") is None and ready_ts is not None:
                record["ready_ts"] = ready_ts

            if node_name:
                record["node_name"] = node_name

            if node_name in nodes and nodes[node_name].get("driver_ready_ts") is None and record.get("ready_ts") is not None:
                nodes[node_name]["driver_ready_ts"] = record["ready_ts"]
                nodes[node_name]["driver_pod_name"] = name

        for item in qwen_pod_payload.get("items", []):
            metadata_obj = item.get("metadata") or {}
            status_obj = item.get("status") or {}
            name = metadata_obj.get("name")
            uid = metadata_obj.get("uid")
            if not name or not uid:
                continue

            container_started_ts = None
            for container_status in status_obj.get("containerStatuses") or []:
                running_state = (container_status.get("state") or {}).get("running") or {}
                if running_state.get("startedAt"):
                    container_started_ts = parse_ts(running_state.get("startedAt"))
                    break

            record = qwen_pods.setdefault(
                uid,
                {
                    "uid": uid,
                    "name": name,
                    "component": (metadata_obj.get("labels") or {}).get("component", ""),
                    "node_name": (item.get("spec") or {}).get("nodeName", ""),
                    "container_name": next(
                        (
                            container.get("name", "")
                            for container in ((item.get("spec") or {}).get("containers") or [])
                            if container.get("name") != "istio-proxy"
                        ),
                        "",
                    ),
                    "image": next(
                        (
                            container.get("image", "")
                            for container in ((item.get("spec") or {}).get("containers") or [])
                            if container.get("name") != "istio-proxy"
                        ),
                        "",
                    ),
                    "created_ts": parse_ts(metadata_obj.get("creationTimestamp")),
                    "first_seen_ts": polled_at,
                    "scheduled_ts": condition_transition(item, "PodScheduled"),
                    "scheduled_event_ts": None,
                    "pulling_ts": None,
                    "pulled_ts": None,
                    "started_event_ts": None,
                    "container_started_ts": container_started_ts,
                    "ready_ts": condition_transition(item, "Ready"),
                    "phase": status_obj.get("phase", ""),
                },
            )

            if record.get("scheduled_ts") is None:
                record["scheduled_ts"] = condition_transition(item, "PodScheduled")
            if record.get("ready_ts") is None:
                record["ready_ts"] = condition_transition(item, "Ready")
            if record.get("container_started_ts") is None and container_started_ts is not None:
                record["container_started_ts"] = container_started_ts
            if (item.get("spec") or {}).get("nodeName"):
                record["node_name"] = (item.get("spec") or {}).get("nodeName", "")

        update_event_fields(qwen_pods, qwen_events_payload.get("items", []))
        update_event_fields(driver_pods, gpu_operator_events_payload.get("items", []))

        ready_gpu_nodes = sum(1 for record in nodes.values() if record.get("ready_ts") is not None)
        ready_qwen_pods = sum(1 for record in qwen_pods.values() if record.get("ready_ts") is not None)
        ready_driver_pods = sum(1 for record in driver_pods.values() if record.get("ready_ts") is not None)

        snapshots.append(
            {
                "timestamp": iso_or_empty(polled_at),
                "gpu_nodes_seen": len(nodes),
                "gpu_nodes_ready": ready_gpu_nodes,
                "driver_pods_seen": len(driver_pods),
                "driver_pods_ready": ready_driver_pods,
                "qwen_pods_seen": len(qwen_pods),
                "qwen_pods_ready": ready_qwen_pods,
                "hpa": [
                    {
                        "name": (item.get("metadata") or {}).get("name", ""),
                        "current_replicas": (item.get("status") or {}).get("currentReplicas", 0),
                        "desired_replicas": (item.get("status") or {}).get("desiredReplicas", 0),
                    }
                    for item in hpa_payload.get("items", [])
                ],
                "scaledobjects": [
                    {
                        "name": (item.get("metadata") or {}).get("name", ""),
                        "ready": next(
                            (
                                condition.get("status")
                                for condition in ((item.get("status") or {}).get("conditions") or [])
                                if condition.get("type") == "Ready"
                            ),
                            "Unknown",
                        ),
                        "active": next(
                            (
                                condition.get("status")
                                for condition in ((item.get("status") or {}).get("conditions") or [])
                                if condition.get("type") == "Active"
                            ),
                            "Unknown",
                        ),
                    }
                    for item in scaledobject_payload.get("items", [])
                ],
            }
        )

        write_json(output_dir / "latest-state.json", {
            "nodes": [serialize_node(record) for record in nodes.values()],
            "driver_pods": [serialize_driver(record) for record in driver_pods.values()],
            "qwen_pods": [serialize_qwen(record) for record in qwen_pods.values()],
            "snapshots": snapshots[-10:],
        })

        time.sleep(args.poll_interval)

    write_json(output_dir / "nodes.json", [serialize_node(record) for record in nodes.values()])
    write_json(output_dir / "driver-pods.json", [serialize_driver(record) for record in driver_pods.values()])
    write_json(output_dir / "qwen-pods.json", [serialize_qwen(record) for record in qwen_pods.values()])
    write_json(output_dir / "snapshots.json", snapshots)

    write_nodes_csv(output_dir / "nodes.csv", nodes)
    write_driver_csv(output_dir / "driver-pods.csv", driver_pods)
    write_qwen_csv(output_dir / "qwen-pods.csv", qwen_pods)

    summary = {
        "finished_at": utc_now(),
        "gpu_nodes_seen": len(nodes),
        "gpu_nodes_ready": sum(1 for record in nodes.values() if record.get("ready_ts") is not None),
        "driver_pods_seen": len(driver_pods),
        "driver_pods_ready": sum(1 for record in driver_pods.values() if record.get("ready_ts") is not None),
        "qwen_pods_seen": len(qwen_pods),
        "qwen_pods_ready": sum(1 for record in qwen_pods.values() if record.get("ready_ts") is not None),
    }
    write_json(output_dir / "summary.json", summary)
    return 0


def serialize_node(record: dict[str, Any]) -> dict[str, Any]:
    return {
        "name": record.get("name", ""),
        "capacity_type": record.get("capacity_type", ""),
        "created_ts": iso_or_empty(record.get("created_ts")),
        "first_seen_ts": iso_or_empty(record.get("first_seen_ts")),
        "ready_ts": iso_or_empty(record.get("ready_ts")),
        "gpu_allocatable_ts": iso_or_empty(record.get("gpu_allocatable_ts")),
        "driver_ready_ts": iso_or_empty(record.get("driver_ready_ts")),
        "driver_pod_name": record.get("driver_pod_name", ""),
        "ready_seconds_from_creation": seconds_between(record.get("created_ts"), record.get("ready_ts")),
        "gpu_allocatable_seconds_from_creation": seconds_between(record.get("created_ts"), record.get("gpu_allocatable_ts")),
        "driver_ready_seconds_from_creation": seconds_between(record.get("created_ts"), record.get("driver_ready_ts")),
    }


def serialize_driver(record: dict[str, Any]) -> dict[str, Any]:
    return {
        "uid": record.get("uid", ""),
        "name": record.get("name", ""),
        "node_name": record.get("node_name", ""),
        "created_ts": iso_or_empty(record.get("created_ts")),
        "first_seen_ts": iso_or_empty(record.get("first_seen_ts")),
        "pulling_ts": iso_or_empty(record.get("pulling_ts")),
        "pulled_ts": iso_or_empty(record.get("pulled_ts")),
        "ready_ts": iso_or_empty(record.get("ready_ts")),
        "phase": record.get("phase", ""),
        "image_pull_seconds": seconds_between(record.get("pulling_ts"), record.get("pulled_ts")),
        "ready_seconds_from_creation": seconds_between(record.get("created_ts"), record.get("ready_ts")),
    }


def serialize_qwen(record: dict[str, Any]) -> dict[str, Any]:
    return {
        "uid": record.get("uid", ""),
        "name": record.get("name", ""),
        "component": record.get("component", ""),
        "node_name": record.get("node_name", ""),
        "created_ts": iso_or_empty(record.get("created_ts")),
        "first_seen_ts": iso_or_empty(record.get("first_seen_ts")),
        "scheduled_ts": iso_or_empty(record.get("scheduled_ts")),
        "scheduled_event_ts": iso_or_empty(record.get("scheduled_event_ts")),
        "pulling_ts": iso_or_empty(record.get("pulling_ts")),
        "pulled_ts": iso_or_empty(record.get("pulled_ts")),
        "started_event_ts": iso_or_empty(record.get("started_event_ts")),
        "container_started_ts": iso_or_empty(record.get("container_started_ts")),
        "ready_ts": iso_or_empty(record.get("ready_ts")),
        "phase": record.get("phase", ""),
        "image_pull_seconds": seconds_between(record.get("pulling_ts"), record.get("pulled_ts")),
        "ready_seconds_from_creation": seconds_between(record.get("created_ts"), record.get("ready_ts")),
        "ready_seconds_from_pull_start": seconds_between(record.get("pulling_ts"), record.get("ready_ts")),
    }


def write_nodes_csv(path: Path, records: dict[str, dict[str, Any]]) -> None:
    with path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(serialize_node(next(iter(records.values()))) .keys()) if records else [
            "name", "capacity_type", "created_ts", "first_seen_ts", "ready_ts", "gpu_allocatable_ts", "driver_ready_ts", "driver_pod_name", "ready_seconds_from_creation", "gpu_allocatable_seconds_from_creation", "driver_ready_seconds_from_creation"
        ])
        writer.writeheader()
        for record in sorted(records.values(), key=lambda item: item.get("name", "")):
            writer.writerow(serialize_node(record))


def write_driver_csv(path: Path, records: dict[str, dict[str, Any]]) -> None:
    with path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(serialize_driver(next(iter(records.values()))).keys()) if records else [
            "uid", "name", "node_name", "created_ts", "first_seen_ts", "pulling_ts", "pulled_ts", "ready_ts", "phase", "image_pull_seconds", "ready_seconds_from_creation"
        ])
        writer.writeheader()
        for record in sorted(records.values(), key=lambda item: item.get("name", "")):
            writer.writerow(serialize_driver(record))


def write_qwen_csv(path: Path, records: dict[str, dict[str, Any]]) -> None:
    with path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(serialize_qwen(next(iter(records.values()))).keys()) if records else [
            "uid", "name", "component", "node_name", "created_ts", "first_seen_ts", "scheduled_ts", "scheduled_event_ts", "pulling_ts", "pulled_ts", "started_event_ts", "container_started_ts", "ready_ts", "phase", "image_pull_seconds", "ready_seconds_from_creation", "ready_seconds_from_pull_start"
        ])
        writer.writeheader()
        for record in sorted(records.values(), key=lambda item: item.get("name", "")):
            writer.writerow(serialize_qwen(record))


if __name__ == "__main__":
    sys.exit(main())