#!/usr/bin/env bash

set -o nounset
set -o errexit
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=scripts/lib/config.sh
source "${SCRIPT_DIR}/lib/config.sh"
# shellcheck source=scripts/lib/logging.sh
source "${SCRIPT_DIR}/lib/logging.sh"
# shellcheck source=scripts/lib/mounts.sh
source "${SCRIPT_DIR}/lib/mounts.sh"
# shellcheck source=scripts/lib/profile.sh
source "${SCRIPT_DIR}/lib/profile.sh"

function cleanup() {
  set +o errexit

  if [ -n "${TARGET_ROOT:-}" ] && [ -d "${TARGET_ROOT:-}" ]; then
    unmount_mount_tree "${TARGET_ROOT}" || true
  fi

  if [ -n "${TARGET_LOOP_DEVICE:-}" ]; then
    detach_loop_device "${TARGET_LOOP_DEVICE}" || true
  fi
}
trap cleanup EXIT

function restore_rootfs_artifact() {
  if [ ! -f "${ROOTFS_ARTIFACT_PATH}" ]; then
    printf 'Missing rootfs artifact: %s\n' "${ROOTFS_ARTIFACT_PATH}" >&2
    return 1
  fi

  tar --zstd --acls --xattrs --same-owner -C "${TARGET_ROOT}" -xpf "${ROOTFS_ARTIFACT_PATH}"
}

function main() {
  require_root
  resolve_build_context "${1:-${BUILD_VERSION:-}}"
  ensure_directories "${TMP_ROOT}" "${BUILD_WORKDIR}"

  ASSEMBLY_STAGE_DIR="$(prepare_stage_workdir assemble)"
  readonly ASSEMBLY_STAGE_DIR
  TARGET_ROOT="${ASSEMBLY_STAGE_DIR}/mount"
  export TARGET_ROOT
  mkdir -p "${TARGET_ROOT}"

  # shellcheck source=images/base.sh
  source "${PROJECT_ROOT}/images/base.sh"

  log_step "Stage 2: creating raw staging image"
  rm -f "${STAGING_IMAGE_PATH}"
  create_partitioned_raw_image "${STAGING_IMAGE_PATH}" "${RESOLVED_FINAL_DISK_SIZE}"
  mount_new_raw_image "${STAGING_IMAGE_PATH}" "${TARGET_ROOT}"

  log_step "Stage 2: restoring common rootfs artifact"
  restore_rootfs_artifact

  log_step "Stage 2: applying bootable disk customization"
  configure_base_image

  log_step "Stage 2: applying ${RESOLVED_IMAGE_PROFILE} profile customization"
  apply_profile_image_customization

  log_step "Stage 2: finalizing raw staging image"
  finalize_base_image
  finalize_mounted_image "${TARGET_ROOT}"
}

main "${1:-}"
