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

IMAGE_SYNC_ACR_ACCESS_TOKEN=""

IMAGE_SYNC_IMPORTED_REFS=""

image_sync_skopeo_multi_arch_mode() {
  local mode="${IMAGE_SYNC_SKOPEO_MULTI_ARCH:-all}"

  case "${mode}" in
    all|system|index-only)
      printf '%s\n' "${mode}"
      ;;
    *)
      fail "IMAGE_SYNC_SKOPEO_MULTI_ARCH must be one of: all, system, index-only"
      ;;
  esac
}

image_sync_selected_tool() {
  local tool="${IMAGE_SYNC_TOOL:-az-acr-import}"

  case "${tool}" in
    az-acr-import|skopeo)
      printf '%s\n' "${tool}"
      ;;
    *)
      fail "IMAGE_SYNC_TOOL must be one of: az-acr-import, skopeo"
      ;;
  esac
}

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

image_sync_require_backend_tools() {
  need_cmd az

  if [[ "$(image_sync_selected_tool)" == "skopeo" ]]; then
    need_cmd skopeo
  fi
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

image_sync_ensure_destination_credentials() {
  image_sync_ensure_acr_login_server
  image_sync_require_backend_tools

  if [[ -n "${IMAGE_SYNC_DESTINATION_USERNAME:-}" && -n "${IMAGE_SYNC_DESTINATION_PASSWORD:-}" ]]; then
    return
  fi

  if [[ -z "${IMAGE_SYNC_ACR_ACCESS_TOKEN}" ]]; then
    IMAGE_SYNC_ACR_ACCESS_TOKEN="$(az acr login --name "${ACR_NAME}" --expose-token --query accessToken -o tsv --only-show-errors)"
  fi

  [[ -n "${IMAGE_SYNC_ACR_ACCESS_TOKEN}" ]] || fail "Failed to acquire an ACR access token for ${ACR_NAME}"

  export IMAGE_SYNC_DESTINATION_USERNAME="00000000-0000-0000-0000-000000000000"
  export IMAGE_SYNC_DESTINATION_PASSWORD="${IMAGE_SYNC_ACR_ACCESS_TOKEN}"
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

image_sync_validate_source_credentials() {
  local source_username="$1"
  local source_password="$2"

  if [[ -n "${source_password}" && -z "${source_username}" ]]; then
    fail "Image sync source username is required when a source password is provided"
  fi

  if [[ -n "${source_username}" && -z "${source_password}" ]]; then
    fail "Image sync source password is required when a source username is provided"
  fi
}

image_sync_run_az_acr_import() {
  local source_ref="$1"
  local target_ref="$2"
  local source_username="$3"
  local source_password="$4"
  local attempt
  local -a import_args=(
    --name "${ACR_NAME}"
    --resource-group "${ACR_RESOURCE_GROUP}"
    --source "${source_ref}"
    --image "${target_ref}"
    --force
    --only-show-errors
  )

  image_sync_validate_source_credentials "${source_username}" "${source_password}"

  if [[ -n "${source_username}" ]]; then
    import_args+=(--username "${source_username}" --password "${source_password}")
  fi

  if [[ "${IMAGE_SYNC_AZ_ACR_IMPORT_NO_WAIT:-false}" == "true" ]]; then
    import_args+=(--no-wait)
  fi

  for attempt in 1 2 3; do
    if az acr import "${import_args[@]}" >/dev/null; then
      if [[ "${IMAGE_SYNC_AZ_ACR_IMPORT_NO_WAIT:-false}" == "true" ]]; then
        log "Submitted background import ${source_ref} -> ${ACR_LOGIN_SERVER}/${target_ref}"
      else
        log "Mirrored ${source_ref} -> ${ACR_LOGIN_SERVER}/${target_ref}"
      fi
      return
    fi

    if [[ "${attempt}" != "3" ]]; then
      warn "Retrying az acr import (${attempt}/3): ${source_ref}"
      sleep 10
    fi
  done

  fail "Failed to mirror ${source_ref} into ${ACR_NAME} via az acr import"
}

image_sync_run_skopeo_copy() {
  local source_ref="$1"
  local target_ref="$2"
  local source_username="$3"
  local source_password="$4"
  local attempt
  local multi_arch_mode

  multi_arch_mode="$(image_sync_skopeo_multi_arch_mode)"
  local -a copy_args=(
    copy
    --retry-times 3
    --multi-arch "${multi_arch_mode}"
    "docker://${source_ref}"
    "docker://${ACR_LOGIN_SERVER}/${target_ref}"
  )

  image_sync_validate_source_credentials "${source_username}" "${source_password}"
  image_sync_ensure_destination_credentials

  copy_args+=(--dest-creds "${IMAGE_SYNC_DESTINATION_USERNAME}:${IMAGE_SYNC_DESTINATION_PASSWORD}")

  if [[ -n "${source_username}" ]]; then
    copy_args+=(--src-creds "${source_username}:${source_password}")
  fi

  for attempt in 1 2 3; do
    if skopeo "${copy_args[@]}" >/dev/null; then
      log "Mirrored ${source_ref} -> ${ACR_LOGIN_SERVER}/${target_ref} via skopeo (multi-arch: ${multi_arch_mode})"
      return
    fi

    if [[ "${attempt}" != "3" ]]; then
      warn "Retrying skopeo copy (${attempt}/3): ${source_ref}"
      sleep 10
    fi
  done

  fail "Failed to mirror ${source_ref} into ${ACR_NAME} via skopeo"
}

image_sync_import_ref() {
  local source_ref="$1"
  local target_ref="${2:-$1}"
  local source_username="${3:-}"
  local source_password="${4:-}"
  local tool

  image_sync_require_backend_tools
  image_sync_ensure_acr_login_server
  tool="$(image_sync_selected_tool)"

  if ! image_sync_note_import "${target_ref}"; then
    return
  fi

  if image_sync_target_ref_exists "${target_ref}"; then
    log "Image already present in ${ACR_NAME}: ${ACR_LOGIN_SERVER}/${target_ref}"
    return
  fi

  case "${tool}" in
    az-acr-import)
      image_sync_run_az_acr_import "${source_ref}" "${target_ref}" "${source_username}" "${source_password}"
      ;;
    skopeo)
      image_sync_run_skopeo_copy "${source_ref}" "${target_ref}" "${source_username}" "${source_password}"
      ;;
  esac
}
