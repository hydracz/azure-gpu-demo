#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../../common.sh"

load_env
ensure_tooling
ensure_aks_kubeconfig

require_env DRAGONFLY_NAMESPACE DRAGONFLY_RELEASE_NAME DRAGONFLY_CACHE_WARMER_NAME

DRAGONFLY_CONTAINERD_CONFIG_DAEMONSET_NAME="${DRAGONFLY_CONTAINERD_CONFIG_DAEMONSET_NAME:-dragonfly-containerd-configurer}"
DRAGONFLY_CONTAINERD_CONFIG_CONFIGMAP_NAME="${DRAGONFLY_CONTAINERD_CONFIG_CONFIGMAP_NAME:-dragonfly-containerd-config}"

kubectl -n "${DRAGONFLY_NAMESPACE}" delete daemonset "${DRAGONFLY_CACHE_WARMER_NAME}" --ignore-not-found >/dev/null 2>&1 || true
kubectl -n "${DRAGONFLY_NAMESPACE}" delete daemonset "${DRAGONFLY_CONTAINERD_CONFIG_DAEMONSET_NAME}" --ignore-not-found >/dev/null 2>&1 || true
kubectl -n "${DRAGONFLY_NAMESPACE}" delete configmap "${DRAGONFLY_CONTAINERD_CONFIG_CONFIGMAP_NAME}" --ignore-not-found >/dev/null 2>&1 || true

if helm -n "${DRAGONFLY_NAMESPACE}" status "${DRAGONFLY_RELEASE_NAME}" >/dev/null 2>&1; then
  log "Uninstalling Dragonfly release ${DRAGONFLY_RELEASE_NAME}"
  helm uninstall "${DRAGONFLY_RELEASE_NAME}" -n "${DRAGONFLY_NAMESPACE}"
else
  log "Dragonfly release ${DRAGONFLY_RELEASE_NAME} is not installed"
fi

kubectl -n "${DRAGONFLY_NAMESPACE}" get pods >/dev/null 2>&1 || true
log "Dragonfly cleanup completed"