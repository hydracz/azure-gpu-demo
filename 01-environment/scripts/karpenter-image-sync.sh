#!/usr/bin/env bash

sync_karpenter_image() {
  local source_repo="${KARPENTER_IMAGE_REPOSITORY:-${KARPENTER_IMAGE_REPO:-}}"
  local source_tag="${KARPENTER_IMAGE_TAG:-}"

  [[ -n "${source_repo}" ]] || fail "KARPENTER_IMAGE_REPOSITORY or KARPENTER_IMAGE_REPO is required"
  [[ -n "${source_tag}" ]] || fail "KARPENTER_IMAGE_TAG is required"

  KARPENTER_TARGET_IMAGE_REPOSITORY="$(image_sync_target_repo_for_source_repo "${source_repo}")"
  export KARPENTER_TARGET_IMAGE_REPOSITORY
  image_sync_write_env_if_available KARPENTER_TARGET_IMAGE_REPOSITORY "${KARPENTER_TARGET_IMAGE_REPOSITORY}"

  log "Karpenter image mirror plan:"
  log "  source : ${source_repo}:${source_tag}"
  log "  target : ${KARPENTER_TARGET_IMAGE_REPOSITORY}:${source_tag}"

  image_sync_import_ref "${source_repo}:${source_tag}" "${source_repo}:${source_tag}"
}