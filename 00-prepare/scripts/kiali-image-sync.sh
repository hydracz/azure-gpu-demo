#!/usr/bin/env bash

KIALI_PROXY_SOURCE_IMAGE="mcr.microsoft.com/azuremonitor/auth-proxy/prod/aad-auth-proxy/images/aad-auth-proxy:0.1.0-main-04-10-2024-7067ac84"

kiali_image_tag() {
  local chart_version="$1"

  [[ -n "${chart_version}" ]] || fail "Kiali chart version is required"

  if [[ "${chart_version}" == v* ]]; then
    printf '%s\n' "${chart_version}"
  else
    printf 'v%s\n' "${chart_version}"
  fi
}

sync_kiali_images() {
  local kiali_version="${ISTIO_KIALI_OPERATOR_CHART_VERSION:-}"
  local kiali_tag

  [[ -n "${kiali_version}" ]] || fail "ISTIO_KIALI_OPERATOR_CHART_VERSION is required to mirror Kiali images"

  kiali_tag="$(kiali_image_tag "${kiali_version}")"

  ISTIO_KIALI_OPERATOR_TARGET_IMAGE_REPOSITORY="$(image_sync_target_repo_for_source_repo "quay.io/kiali/kiali-operator")"
  ISTIO_KIALI_TARGET_IMAGE_NAME="$(image_sync_target_repo_for_source_repo "quay.io/kiali/kiali")"
  ISTIO_KIALI_PROXY_TARGET_IMAGE="$(image_sync_target_repo_for_source_repo "${KIALI_PROXY_SOURCE_IMAGE%%:*}"):${KIALI_PROXY_SOURCE_IMAGE##*:}"
  ISTIO_KIALI_IMAGE_TAG="${kiali_tag}"

  export ISTIO_KIALI_OPERATOR_TARGET_IMAGE_REPOSITORY
  export ISTIO_KIALI_TARGET_IMAGE_NAME
  export ISTIO_KIALI_PROXY_TARGET_IMAGE
  export ISTIO_KIALI_IMAGE_TAG

  image_sync_write_env_if_available ISTIO_KIALI_OPERATOR_TARGET_IMAGE_REPOSITORY "${ISTIO_KIALI_OPERATOR_TARGET_IMAGE_REPOSITORY}"
  image_sync_write_env_if_available ISTIO_KIALI_TARGET_IMAGE_NAME "${ISTIO_KIALI_TARGET_IMAGE_NAME}"
  image_sync_write_env_if_available ISTIO_KIALI_PROXY_TARGET_IMAGE "${ISTIO_KIALI_PROXY_TARGET_IMAGE}"
  image_sync_write_env_if_available ISTIO_KIALI_IMAGE_TAG "${ISTIO_KIALI_IMAGE_TAG}"

  log "Kiali image mirror plan:"
  log "  operator : quay.io/kiali/kiali-operator:${kiali_tag}"
  log "  server   : quay.io/kiali/kiali:${kiali_tag}"
  log "  proxy    : ${KIALI_PROXY_SOURCE_IMAGE}"

  image_sync_import_ref "quay.io/kiali/kiali-operator:${kiali_tag}" "quay.io/kiali/kiali-operator:${kiali_tag}"
  image_sync_import_ref "quay.io/kiali/kiali:${kiali_tag}" "quay.io/kiali/kiali:${kiali_tag}"
  image_sync_import_ref "${KIALI_PROXY_SOURCE_IMAGE}" "${KIALI_PROXY_SOURCE_IMAGE}"
}
