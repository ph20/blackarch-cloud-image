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

function setup_logging() {
  ensure_directories "${ROOTFS_OUTPUT_DIR}" "${IMAGE_OUTPUT_DIR}" "${TMP_ROOT}"

  BUILD_LOG="${IMAGE_OUTPUT_DIR}/${RESOLVED_IMAGE_NAME_PREFIX}-${BUILD_VERSION}.build.log"
  export BUILD_LOG
  : > "${BUILD_LOG}"
  chown_to_invoking_user "${BUILD_LOG}" 2>/dev/null || true

  exec 3>&1
  STATUS_FD_READY=1
  export STATUS_FD_READY
  exec >>"${BUILD_LOG}" 2>&1

  log_step "Writing build log to ${BUILD_LOG}"

  if [ "${BUILD_VERSION_WAS_DEFAULTED}" -eq 1 ]; then
    status_line "No explicit build version was provided."
    status_line "Auto-selected build version ${BUILD_VERSION}"
  fi
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
  setup_logging

  log_step "Initializing staged build workspace"
  rm -rf "${BUILD_WORKDIR}"
  mkdir -p "${BUILD_WORKDIR}"

  bash "${PROJECT_ROOT}/scripts/build-rootfs.sh" "${BUILD_VERSION}"
  bash "${PROJECT_ROOT}/scripts/assemble-image.sh" "${BUILD_VERSION}"
  bash "${PROJECT_ROOT}/scripts/export-image.sh" "${BUILD_VERSION}"

  log_step "Build completed"
  status_line "Rootfs artifact: ${ROOTFS_ARTIFACT_PATH}"
  status_line "Image artifact: ${FINAL_IMAGE_PATH}"
  status_line "Checksum: ${FINAL_IMAGE_CHECKSUM_PATH}"
  status_line "Build log: ${BUILD_LOG}"
}

main "${1:-}"
