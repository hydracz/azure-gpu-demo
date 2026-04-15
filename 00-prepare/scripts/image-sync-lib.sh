#!/usr/bin/env bash

if ! declare -F log >/dev/null 2>&1; then
  log() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
  }
fi

if ! declare -F warn >/dev/null 2>&1; then
  warn() {
    printf '[%s] WARNING: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2
  }
fi

if ! declare -F fail >/dev/null 2>&1; then
  fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
  }
fi

if ! declare -F need_cmd >/dev/null 2>&1; then
  need_cmd() {
    command -v "$1" >/dev/null 2>&1 || fail "missing required command: $1"
  }
fi

if ! declare -F write_generated_env >/dev/null 2>&1; then
  write_generated_env() {
    return 0
  }
fi

IMAGE_SYNC_IMPORTED_REFS=""

image_sync_note_import() {
  local target_ref="$1"

  case "${IMAGE_SYNC_IMPORTED_REFS}" in
    *$'\n'"${target_ref}"$'\n'*)
      return 1
      ;;
  esac

  IMAGE_SYNC_IMPORTED_REFS+=$'\n'"${target_ref}"$'\n'
  return 0
}

image_sync_write_env_if_available() {
  local key="$1"
  local value="$2"

  if declare -F write_generated_env >/dev/null 2>&1; then
    write_generated_env "${key}" "${value}"
  fi
}

image_sync_normalize_azure_env() {
  if [[ -z "${AZURE_SUBSCRIPTION_ID:-}" && -n "${AZ_SUBSCRIPTION_ID:-}" ]]; then
    export AZURE_SUBSCRIPTION_ID="${AZ_SUBSCRIPTION_ID}"
  fi

  [[ -n "${AZURE_SUBSCRIPTION_ID:-}" ]] || fail "AZURE_SUBSCRIPTION_ID or AZ_SUBSCRIPTION_ID is required for image sync"
  if [[ -z "${ACR_RESOURCE_GROUP:-}" && -n "${RESOURCE_GROUP:-}" ]]; then
    export ACR_RESOURCE_GROUP="${RESOURCE_GROUP}"
  fi

  [[ -n "${ACR_RESOURCE_GROUP:-}" ]] || fail "ACR_RESOURCE_GROUP or RESOURCE_GROUP is required for image sync"
  [[ -n "${ACR_NAME:-}" ]] || fail "ACR_NAME is required for image sync"
}

image_sync_ensure_acr_login_server() {
  if [[ -n "${ACR_LOGIN_SERVER:-}" ]]; then
    return
  fi

  image_sync_normalize_azure_env
  need_cmd az

  az account set --subscription "${AZURE_SUBSCRIPTION_ID}" --only-show-errors >/dev/null
  ACR_LOGIN_SERVER="$(az acr show --name "${ACR_NAME}" --resource-group "${ACR_RESOURCE_GROUP}" --query loginServer -o tsv --only-show-errors)"
  [[ -n "${ACR_LOGIN_SERVER}" ]] || fail "Failed to resolve login server for ACR ${ACR_NAME}"

  export ACR_LOGIN_SERVER
  image_sync_write_env_if_available ACR_LOGIN_SERVER "${ACR_LOGIN_SERVER}"
}

image_sync_target_repo_for_source_repo() {
  local source_repo="$1"

  image_sync_ensure_acr_login_server
  printf '%s/%s' "${ACR_LOGIN_SERVER}" "${source_repo}"
}

image_sync_target_ref_exists() {
  local target_ref="$1"
  local repository="${target_ref%:*}"
  local tag="${target_ref##*:}"
  local count="0"

  image_sync_ensure_acr_login_server

  [[ -n "${repository}" && -n "${tag}" && "${repository}" != "${tag}" ]] || return 1

  count="$(az acr repository show-tags \
    --name "${ACR_NAME}" \
    --resource-group "${ACR_RESOURCE_GROUP}" \
    --repository "${repository}" \
    --query "[?@=='${tag}'] | length(@)" \
    -o tsv \
    --only-show-errors 2>/dev/null || true)"

  [[ "${count}" == "1" ]]
}

image_sync_import_ref() {
  local source_ref="$1"
  local target_ref="${2:-$1}"
  local attempt

  image_sync_ensure_acr_login_server

  if ! image_sync_note_import "${target_ref}"; then
    return
  fi

  if image_sync_target_ref_exists "${target_ref}"; then
    log "Image already present in ${ACR_NAME}: ${ACR_LOGIN_SERVER}/${target_ref}"
    return
  fi

  for attempt in 1 2 3; do
    if az acr import \
      --name "${ACR_NAME}" \
      --resource-group "${ACR_RESOURCE_GROUP}" \
      --source "${source_ref}" \
      --image "${target_ref}" \
      --force \
      --only-show-errors >/dev/null; then
      log "Mirrored ${source_ref} -> ${ACR_LOGIN_SERVER}/${target_ref}"
      return
    fi

    if [[ "${attempt}" != "3" ]]; then
      warn "Retrying image import (${attempt}/3): ${source_ref}"
      sleep 10
    fi
  done

  fail "Failed to mirror ${source_ref} into ${ACR_NAME}"
}
