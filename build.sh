#!/usr/bin/env bash

set -o nounset
set -o errexit
set -o pipefail
set -o errtrace

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_ROOT

# shellcheck source=scripts/lib/common.sh
source "${PROJECT_ROOT}/scripts/lib/common.sh"
# shellcheck source=scripts/lib/config.sh
source "${PROJECT_ROOT}/scripts/lib/config.sh"
# shellcheck source=scripts/lib/logging.sh
source "${PROJECT_ROOT}/scripts/lib/logging.sh"
# shellcheck source=scripts/lib/manifest.sh
source "${PROJECT_ROOT}/scripts/lib/manifest.sh"

function setup_logging() {
  ensure_directories "${ROOTFS_OUTPUT_DIR}" "${IMAGE_OUTPUT_DIR}" "${TMP_ROOT}"

  BUILD_LOG="${BUILD_LOG_PATH}"
  export BUILD_LOG
  : > "${BUILD_LOG}"
  chown_to_invoking_user "${BUILD_LOG}" 2>/dev/null || true

  exec 3>&1
  STATUS_FD_READY=1
  export STATUS_FD_READY
  exec >>"${BUILD_LOG}" 2>&1

  log_step "Writing build log to ${BUILD_LOG}"
  status_line "Release version: ${RELEASE_VERSION}"
  status_line "Build ID: ${BUILD_ID}"
  status_line "Artifact version: ${ARTIFACT_VERSION}"
  status_line "Git commit: ${GIT_COMMIT}"
  status_line "Git tag: ${GIT_TAG}"
  status_line "Profile: ${RESOLVED_IMAGE_PROFILE}"
  status_line "Reuse rootfs artifact: ${REUSE_ROOTFS:-false}"

  if [ "${BUILD_ID_SOURCE}" = "legacy-build-version-env" ]; then
    status_line "Using legacy BUILD_VERSION as BUILD_ID."
  fi

  if [ "${BUILD_ID_WAS_DEFAULTED}" -eq 1 ]; then
    status_line "No explicit build ID was provided."
    status_line "Auto-selected build ID ${BUILD_ID}"
  fi
}

function reuse_rootfs_requested() {
  [ "${REUSE_ROOTFS:-false}" = "true" ]
}

function can_reuse_rootfs_artifact() {
  if ! reuse_rootfs_requested; then
    return 1
  fi

  if [ ! -f "${ROOTFS_ARTIFACT_PATH}" ]; then
    status_line "Rootfs reuse was requested, but no existing artifact was found at ${ROOTFS_ARTIFACT_PATH}."
    return 1
  fi

  if [ ! -f "${ROOTFS_MANIFEST_PATH}" ]; then
    status_line "Rootfs reuse was requested, but the artifact manifest is missing: ${ROOTFS_MANIFEST_PATH}"
    return 1
  fi

  if ! validate_reusable_rootfs_manifest "${ROOTFS_MANIFEST_PATH}"; then
    status_line "Rootfs reuse was requested, but the existing artifact is incompatible with the current Stage 1 configuration."
    return 1
  fi

  ROOTFS_REUSED=1
  export ROOTFS_REUSED
  status_line "Reusing existing rootfs artifact: ${ROOTFS_ARTIFACT_PATH}"
  status_line "Reusing existing rootfs manifest: ${ROOTFS_MANIFEST_PATH}"
  return 0
}

function cleanup() {
  set +o errexit

  if [ -n "${BUILD_WORKDIR:-}" ] && [ -d "${BUILD_WORKDIR:-}" ]; then
    rm -rf "${BUILD_WORKDIR}"
  fi
}

function handle_error() {
  local exit_code=$?

  if [ -n "${BUILD_LOG:-}" ]; then
    status_line "Build failed during step: ${CURRENT_STEP:-unknown}"
    status_line "See build log: ${BUILD_LOG}"
  fi

  exit "${exit_code}"
}

function handle_signal() {
  local signal_name="${1}"
  local exit_code="${2}"

  trap - ERR INT TERM

  status_line "Build interrupted by ${signal_name} during step: ${CURRENT_STEP:-unknown}"

  if [ -n "${BUILD_LOG:-}" ]; then
    status_line "See build log: ${BUILD_LOG}"
  fi

  exit "${exit_code}"
}

trap cleanup EXIT
trap handle_error ERR
trap 'handle_signal SIGINT 130' INT
trap 'handle_signal SIGTERM 143' TERM

function main() {
  require_root
  resolve_build_context "${1:-}"
  ROOTFS_REUSED=0
  export ROOTFS_REUSED
  setup_logging

  log_step "Initializing staged build workspace"
  run_logged rm -rf "${BUILD_WORKDIR}"
  run_logged mkdir -p "${BUILD_WORKDIR}"

  if can_reuse_rootfs_artifact; then
    log_step "Skipping Stage 1: reusing common rootfs"
  else
    log_step "Running Stage 1: build common rootfs"
    run_logged bash "${PROJECT_ROOT}/scripts/build-rootfs.sh" "${BUILD_ID}"
  fi
  log_step "Running Stage 2: assemble profile-specific image"
  run_logged bash "${PROJECT_ROOT}/scripts/assemble-image.sh" "${BUILD_ID}"
  log_step "Running Stage 3: export final artifact"
  run_logged bash "${PROJECT_ROOT}/scripts/export-image.sh" "${BUILD_ID}"

  log_step "Build completed"
  status_line "Rootfs reused: ${ROOTFS_REUSED}"
  status_line "Rootfs artifact: ${ROOTFS_ARTIFACT_PATH}"
  status_line "Rootfs manifest: ${ROOTFS_MANIFEST_PATH}"
  status_line "Image artifact: ${FINAL_IMAGE_PATH}"
  status_line "Checksum: ${FINAL_IMAGE_CHECKSUM_PATH}"
  status_line "Image manifest: ${FINAL_IMAGE_MANIFEST_PATH}"
  status_line "Build log: ${BUILD_LOG}"
}

main "${1:-}"
