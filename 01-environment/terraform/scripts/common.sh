#!/usr/bin/env bash

set -euo pipefail

COMMON_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${COMMON_SCRIPT_DIR}/../../.." && pwd)"
GENERATED_ENV_FILE="${REPO_ROOT}/.generated.env"

log() {
  printf '[terraform] %s\n' "$*"
}

warn() {
  printf '[terraform][warn] %s\n' "$*" >&2
}

fail() {
  printf '[terraform][error] %s\n' "$*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "missing required command: $1"
}

ensure_parent_dir() {
  local target_path="$1"
  local target_dir

  target_dir="$(dirname "${target_path}")"
  mkdir -p "${target_dir}"
}

source_shared_env_preserving_current() {
  local shared_env_file="$1"
  shift || true

  local var_name
  local value_var_name
  local set_var_name

  [[ -n "${shared_env_file}" && -f "${shared_env_file}" ]] || return 0

  for var_name in "$@"; do
    if [[ -n "${!var_name+x}" ]]; then
      value_var_name="__PRESERVE_${var_name}"
      set_var_name="__PRESERVE_SET_${var_name}"
      printf -v "${value_var_name}" '%s' "${!var_name}"
      printf -v "${set_var_name}" '%s' "1"
    fi
  done

  set -a
  # shellcheck disable=SC1090
  source "${shared_env_file}"
  set +a

  for var_name in "$@"; do
    value_var_name="__PRESERVE_${var_name}"
    set_var_name="__PRESERVE_SET_${var_name}"

    if [[ -n "${!set_var_name:-}" ]]; then
      printf -v "${var_name}" '%s' "${!value_var_name}"
      export "${var_name}"
      unset "${value_var_name}" "${set_var_name}"
    fi
  done
}

resolve_ipv4_via_public_dns() {
  local hostname="$1"
  local resolver="${2:-8.8.8.8}"

  nslookup "${hostname}" "${resolver}" 2>/dev/null |
    awk '/^Address: / { print $2 }' |
    grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' |
    tail -n 1
}

rewrite_kubeconfig_server_with_public_dns() {
  local kubeconfig_file="$1"
  local cluster_name
  local server_url
  local server_host
  local server_port
  local resolved_ip
  local rewritten_server

  cluster_name="$(kubectl config view --kubeconfig "${kubeconfig_file}" -o jsonpath='{.clusters[0].name}' 2>/dev/null || true)"
  [[ -n "${cluster_name}" ]] || return 0

  server_url="$(kubectl config view --kubeconfig "${kubeconfig_file}" -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || true)"
  [[ -n "${server_url}" ]] || return 0

  server_host="${server_url#https://}"
  server_host="${server_host%%/*}"
  server_port="443"

  if [[ "${server_host}" == *:* ]]; then
    server_port="${server_host##*:}"
    server_host="${server_host%%:*}"
  fi

  if [[ "${server_host}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    return 0
  fi

  resolved_ip="$(resolve_ipv4_via_public_dns "${server_host}")"
  if [[ -z "${resolved_ip}" ]]; then
    warn "Unable to resolve ${server_host} via public DNS; keeping hostname in kubeconfig"
    return 0
  fi

  rewritten_server="https://${resolved_ip}:${server_port}"
  kubectl config set-cluster "${cluster_name}" \
    --kubeconfig "${kubeconfig_file}" \
    --server="${rewritten_server}" \
    --tls-server-name="${server_host}" \
    >/dev/null

  log "Rewrote kubeconfig server for ${cluster_name} to ${resolved_ip} with TLS server name ${server_host}"
}

kubeconfig_is_usable() {
  local kubeconfig_file="$1"

  [[ -s "${kubeconfig_file}" ]] || return 1

  KUBECONFIG="${kubeconfig_file}" kubectl cluster-info >/dev/null 2>&1
}

write_generated_env() {
  local key="$1"
  local value="$2"

  mkdir -p "$(dirname "${GENERATED_ENV_FILE}")"
  touch "${GENERATED_ENV_FILE}"

  if grep -q "^${key}=" "${GENERATED_ENV_FILE}"; then
    python3 - "${GENERATED_ENV_FILE}" "$key" "$value" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
key = sys.argv[2]
value = sys.argv[3]

def shell_double_quote(raw: str) -> str:
    return raw.replace('\\', '\\\\').replace('"', '\\"').replace('$', '\\$').replace('`', '\\`')

lines = path.read_text(encoding='utf-8').splitlines()
updated = []
for line in lines:
    if line.startswith(f"{key}="):
        updated.append(f'{key}="{shell_double_quote(value)}"')
    else:
        updated.append(line)
path.write_text("\n".join(updated) + "\n", encoding='utf-8')
PY
  else
    python3 - "${GENERATED_ENV_FILE}" "$key" "$value" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
key = sys.argv[2]
value = sys.argv[3]

def shell_double_quote(raw: str) -> str:
    return raw.replace('\\', '\\\\').replace('"', '\\"').replace('$', '\\$').replace('`', '\\`')

with path.open('a', encoding='utf-8') as handle:
    handle.write(f'{key}="{shell_double_quote(value)}"\n')
PY
  fi
}

refresh_aks_kubeconfig() {
  local fetched_mode=""
  local stale_kubeconfigs=()

  need_cmd kubectl

  [[ -n "${KUBECONFIG_FILE:-}" ]] || fail "KUBECONFIG_FILE is required"
  [[ -n "${AZURE_SUBSCRIPTION_ID:-}" ]] || fail "AZURE_SUBSCRIPTION_ID is required"
  [[ -n "${RESOURCE_GROUP:-}" ]] || fail "RESOURCE_GROUP is required"
  [[ -n "${CLUSTER_NAME:-}" ]] || fail "CLUSTER_NAME is required"

  ensure_parent_dir "${KUBECONFIG_FILE}"

  if [[ -e "${KUBECONFIG_FILE}.lock" ]]; then
    warn "Removing legacy kubeconfig lock ${KUBECONFIG_FILE}.lock"
    rm -rf "${KUBECONFIG_FILE}.lock"
  fi

  shopt -s nullglob
  stale_kubeconfigs=("${KUBECONFIG_FILE}.tmp."*)
  shopt -u nullglob
  if (( ${#stale_kubeconfigs[@]} > 0 )); then
    warn "Removing stale kubeconfig temp files for ${KUBECONFIG_FILE}"
    rm -f -- "${stale_kubeconfigs[@]}"
  fi

  if kubeconfig_is_usable "${KUBECONFIG_FILE}"; then
    export AKS_KUBECONFIG_FILE="${KUBECONFIG_FILE}"
    export KUBECONFIG="${KUBECONFIG_FILE}"
    write_generated_env AKS_KUBECONFIG_FILE "${KUBECONFIG_FILE}"
    log "Reusing existing kubeconfig ${KUBECONFIG_FILE} for ${CLUSTER_NAME}"
    return 0
  fi

  need_cmd az

  az account set --subscription "${AZURE_SUBSCRIPTION_ID}" --only-show-errors >/dev/null

  if az aks get-credentials \
    --resource-group "${RESOURCE_GROUP}" \
    --name "${CLUSTER_NAME}" \
    --file "${KUBECONFIG_FILE}" \
    --overwrite-existing \
    --admin \
    --only-show-errors >/dev/null 2>&1; then
    fetched_mode="admin"
  else
    warn "Falling back to user kubeconfig for ${CLUSTER_NAME}"
    if az aks get-credentials \
      --resource-group "${RESOURCE_GROUP}" \
      --name "${CLUSTER_NAME}" \
      --file "${KUBECONFIG_FILE}" \
      --overwrite-existing \
      --only-show-errors >/dev/null 2>&1; then
      fetched_mode="user"
    else
      fail "Failed to fetch AKS kubeconfig for ${CLUSTER_NAME}"
    fi
  fi

  rewrite_kubeconfig_server_with_public_dns "${KUBECONFIG_FILE}"

  export AKS_KUBECONFIG_FILE="${KUBECONFIG_FILE}"
  export KUBECONFIG="${KUBECONFIG_FILE}"
  write_generated_env AKS_KUBECONFIG_FILE "${KUBECONFIG_FILE}"
  log "Fetched AKS ${fetched_mode} kubeconfig for ${CLUSTER_NAME} into ${KUBECONFIG_FILE}"
}

wait_for_cluster_api() {
  local attempt

  for attempt in $(seq 1 30); do
    if kubectl cluster-info >/dev/null 2>&1; then
      return 0
    fi

    warn "Kubernetes API not ready yet for ${CLUSTER_NAME:-cluster}; retry ${attempt}/30"
    sleep 10
  done

  fail "Kubernetes API for ${CLUSTER_NAME:-cluster} did not become ready in time"
}

wait_for_deployment() {
  local namespace="$1"
  local name="$2"
  local attempts="${3:-60}"
  local attempt

  for attempt in $(seq 1 "${attempts}"); do
    if kubectl get deployment "${name}" -n "${namespace}" >/dev/null 2>&1; then
      return 0
    fi

    warn "Waiting for deployment ${namespace}/${name} (${attempt}/${attempts})"
    sleep 10
  done

  fail "Deployment ${namespace}/${name} was not created in time"
}

wait_for_deployment_rollout() {
  local namespace="$1"
  local name="$2"
  local attempts="${3:-60}"
  local sleep_seconds="${4:-10}"
  local attempt
  local status_line
  local generation
  local observed_generation
  local desired_replicas
  local updated_replicas
  local available_replicas
  local available_condition

  wait_for_deployment "${namespace}" "${name}" "${attempts}"

  for attempt in $(seq 1 "${attempts}"); do
    if status_line="$(kubectl get deployment "${name}" -n "${namespace}" -o jsonpath='{.metadata.generation}{"|"}{.status.observedGeneration}{"|"}{.spec.replicas}{"|"}{.status.updatedReplicas}{"|"}{.status.availableReplicas}{"|"}{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null)"; then
      IFS='|' read -r generation observed_generation desired_replicas updated_replicas available_replicas available_condition <<<"${status_line}"

      generation="${generation:-0}"
      observed_generation="${observed_generation:-0}"
      desired_replicas="${desired_replicas:-1}"
      updated_replicas="${updated_replicas:-0}"
      available_replicas="${available_replicas:-0}"

      if [[ "${observed_generation}" == "${generation}" ]] \
        && (( updated_replicas >= desired_replicas )) \
        && (( available_replicas >= desired_replicas )) \
        && [[ "${available_condition}" == *"True"* ]]; then
        return 0
      fi

      warn "Waiting for deployment rollout ${namespace}/${name}: observed=${observed_generation}/${generation} updated=${updated_replicas}/${desired_replicas} available=${available_replicas}/${desired_replicas} (${attempt}/${attempts})"
    else
      warn "Kubernetes API unavailable while checking deployment rollout ${namespace}/${name} (${attempt}/${attempts})"
    fi

    sleep "${sleep_seconds}"
  done

  kubectl describe deployment "${name}" -n "${namespace}" >&2 || true
  fail "Timed out waiting for deployment rollout ${namespace}/${name}"
}

wait_for_daemonset_rollout() {
  local namespace="$1"
  local name="$2"
  local attempts="${3:-60}"
  local sleep_seconds="${4:-10}"
  local attempt
  local status_line
  local desired_number_scheduled
  local updated_number_scheduled
  local number_available
  local number_ready
  local observed_generation
  local generation

  for attempt in $(seq 1 "${attempts}"); do
    if status_line="$(kubectl get daemonset "${name}" -n "${namespace}" -o jsonpath='{.metadata.generation}{"|"}{.status.observedGeneration}{"|"}{.status.desiredNumberScheduled}{"|"}{.status.updatedNumberScheduled}{"|"}{.status.numberAvailable}{"|"}{.status.numberReady}' 2>/dev/null)"; then
      IFS='|' read -r generation observed_generation desired_number_scheduled updated_number_scheduled number_available number_ready <<<"${status_line}"

      generation="${generation:-0}"
      observed_generation="${observed_generation:-0}"
      desired_number_scheduled="${desired_number_scheduled:-0}"
      updated_number_scheduled="${updated_number_scheduled:-0}"
      number_available="${number_available:-0}"
      number_ready="${number_ready:-0}"

      if [[ "${observed_generation}" == "${generation}" ]] \
        && (( updated_number_scheduled >= desired_number_scheduled )) \
        && (( number_available >= desired_number_scheduled )) \
        && (( number_ready >= desired_number_scheduled )); then
        return 0
      fi

      warn "Waiting for daemonset rollout ${namespace}/${name}: observed=${observed_generation}/${generation} updated=${updated_number_scheduled}/${desired_number_scheduled} available=${number_available}/${desired_number_scheduled} ready=${number_ready}/${desired_number_scheduled} (${attempt}/${attempts})"
    else
      warn "Waiting for daemonset ${namespace}/${name} (${attempt}/${attempts})"
    fi

    sleep "${sleep_seconds}"
  done

  kubectl describe daemonset "${name}" -n "${namespace}" >&2 || true
  fail "Timed out waiting for daemonset rollout ${namespace}/${name}"
}

wait_for_crd() {
  local name="$1"
  local attempts="${2:-60}"
  local attempt

  for attempt in $(seq 1 "${attempts}"); do
    if kubectl get crd "${name}" >/dev/null 2>&1; then
      if kubectl get crd "${name}" -o jsonpath='{.status.conditions[?(@.type=="Established")].status}' 2>/dev/null | grep -q 'True'; then
        return 0
      fi

      warn "Waiting for CRD ${name} to become Established (${attempt}/${attempts})"
      sleep 10
      continue
    fi

    warn "Waiting for CRD ${name} (${attempt}/${attempts})"
    sleep 10
  done

  fail "CRD ${name} was not created in time"
}