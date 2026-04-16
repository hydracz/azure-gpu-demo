#!/usr/bin/env bash

set -euo pipefail

log() {
  printf '[azmonitor-sm] %s\n' "$*"
}

warn() {
  printf '[azmonitor-sm][warn] %s\n' "$*" >&2
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    printf '[azmonitor-sm][error] missing required command: %s\n' "$1" >&2
    exit 1
  }
}

need_cmd kubectl
need_cmd python3

if [[ -n "${KUBECONFIG_FILE:-}" ]]; then
  export KUBECONFIG="${KUBECONFIG_FILE}"
fi

SOURCE_GROUP="monitoring.coreos.com"
TARGET_GROUP="azmonitoring.coreos.com"
MIRROR_SUFFIX="-azmonitor"

crd_exists() {
  local name="$1"
  kubectl get crd "${name}" >/dev/null 2>&1
}

sync_monitor_kind() {
  local plural="$1"
  local kind="$2"
  local source_crd="${plural}.${SOURCE_GROUP}"
  local target_crd="${plural}.${TARGET_GROUP}"
  local tmp_dir source_json target_json plan_json

  if ! crd_exists "${source_crd}"; then
    warn "${source_crd} not found, skipping ${kind} mirror sync"
    return 0
  fi

  if ! crd_exists "${target_crd}"; then
    warn "${target_crd} not found, skipping ${kind} mirror sync"
    return 0
  fi

  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "${tmp_dir}"' RETURN

  source_json="${tmp_dir}/${plural}-source.json"
  target_json="${tmp_dir}/${plural}-target.json"
  plan_json="${tmp_dir}/${plural}-plan.json"

  kubectl get "${plural}.${SOURCE_GROUP}" -A -o json >"${source_json}"
  kubectl get "${plural}.${TARGET_GROUP}" -A -o json >"${target_json}"

  python3 - "${source_json}" "${target_json}" "${kind}" "${SOURCE_GROUP}" "${TARGET_GROUP}" "${MIRROR_SUFFIX}" >"${plan_json}" <<'PY'
import json
import sys

source_path, target_path, kind, source_group, target_group, mirror_suffix = sys.argv[1:7]
source_items = json.load(open(source_path, encoding="utf-8")).get("items", [])
target_items = json.load(open(target_path, encoding="utf-8")).get("items", [])


def filtered_annotations(annotations):
    kept = {}
    for key, value in (annotations or {}).items():
        if key == "kubectl.kubernetes.io/last-applied-configuration":
            continue
        if key.startswith("meta.helm.sh/"):
            continue
        kept[key] = value
    return kept


def mirror_name(name):
    return name if name.endswith(mirror_suffix) else f"{name}{mirror_suffix}"


apply = []
expected = set()

for item in source_items:
    metadata = item.get("metadata") or {}
    name = metadata.get("name")
    namespace = metadata.get("namespace")
    spec = item.get("spec") or {}
    if not name or not namespace or not spec:
        continue

    mirrored_name = mirror_name(name)
    expected.add((namespace, mirrored_name))

    annotations = filtered_annotations(metadata.get("annotations"))
    annotations.update(
        {
            "azure-gpu-demo/source-api-group": source_group,
            "azure-gpu-demo/source-kind": kind,
            "azure-gpu-demo/source-name": name,
            "azure-gpu-demo/source-namespace": namespace,
        }
    )

    document = {
        "apiVersion": f"{target_group}/v1",
        "kind": kind,
        "metadata": {
            "name": mirrored_name,
            "namespace": namespace,
            "annotations": annotations,
            "labels": metadata.get("labels") or {},
        },
        "spec": spec,
    }
    apply.append(document)

delete = []
for item in target_items:
    metadata = item.get("metadata") or {}
    annotations = metadata.get("annotations") or {}
    if annotations.get("azure-gpu-demo/source-api-group") != source_group:
        continue
    if annotations.get("azure-gpu-demo/source-kind") != kind:
        continue

    namespace = metadata.get("namespace")
    name = metadata.get("name")
    if not namespace or not name:
        continue
    if (namespace, name) not in expected:
        delete.append({"namespace": namespace, "name": name})

json.dump({"apply": apply, "delete": delete}, sys.stdout)
PY

  python3 - "${plan_json}" <<'PY' | while IFS= read -r manifest; do
import json
import sys

plan = json.load(open(sys.argv[1], encoding="utf-8"))
for document in plan.get("apply", []):
    print(json.dumps(document))
PY
    [[ -n "${manifest}" ]] || continue
    printf '%s\n' "${manifest}" | kubectl apply -f - >/dev/null
  done

  python3 - "${plan_json}" <<'PY' | while IFS=$'\t' read -r namespace name; do
import json
import sys

plan = json.load(open(sys.argv[1], encoding="utf-8"))
for document in plan.get("delete", []):
    print(f"{document['namespace']}\t{document['name']}")
PY
    [[ -n "${namespace}" && -n "${name}" ]] || continue
    log "Deleting stale Azure Monitor ${kind} ${namespace}/${name}"
    kubectl delete "${plural}.${TARGET_GROUP}" "${name}" -n "${namespace}" --ignore-not-found >/dev/null
  done

  log "Azure Monitor ${kind} mirror sync completed"
}

sync_monitor_kind servicemonitors ServiceMonitor
sync_monitor_kind podmonitors PodMonitor

log "Azure Monitor monitor resource sync completed"