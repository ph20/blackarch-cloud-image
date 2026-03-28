#!/usr/bin/env bash

set -o nounset
set -o errexit
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
readonly PROJECT_ROOT

# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=scripts/lib/config.sh
source "${SCRIPT_DIR}/lib/config.sh"
# shellcheck source=scripts/lib/logging.sh
source "${SCRIPT_DIR}/lib/logging.sh"

function default_image_profiles() {
  local -a profile_paths=()
  local profile_path=''

  shopt -s nullglob
  profile_paths=("${PROFILES_DIR}"/*.env)
  shopt -u nullglob

  if [ "${#profile_paths[@]}" -eq 0 ]; then
    printf '\n'
    return 0
  fi

  for profile_path in "${profile_paths[@]}"; do
    basename "${profile_path}" .env
  done | LC_ALL=C sort | paste -sd ' ' -
}

DEFAULT_IMAGE_PROFILES="$(default_image_profiles)"
readonly DEFAULT_IMAGE_PROFILES

function requested_image_profiles() {
  printf '%s\n' "${IMAGE_PROFILES:-${DEFAULT_IMAGE_PROFILES}}"
}

function validate_requested_image_profiles() {
  local profile_list=''
  local profile=''

  profile_list="$(requested_image_profiles)"

  if [ -z "${profile_list}" ]; then
    printf '%s\n' 'IMAGE_PROFILES must not be empty.' >&2
    return 1
  fi

  for profile in ${profile_list}; do
    validate_image_profile_value "${profile}" || return 1
  done
}

function run_profile_build() {
  local profile="${1}"
  local reuse_rootfs="${2}"
  local build_id="${BUILD_ID}"

  status_line "==> Preparing build for profile ${profile} (REUSE_ROOTFS=${reuse_rootfs})"
  IMAGE_PROFILE="${profile}" REUSE_ROOTFS="${reuse_rootfs}" BUILD_ID="${build_id}" BUILD_VERSION="${build_id}" \
    bash "${PROJECT_ROOT}/scripts/check-build-env.sh"

  status_line "==> Starting build for profile ${profile}"
  IMAGE_PROFILE="${profile}" REUSE_ROOTFS="${reuse_rootfs}" BUILD_ID="${build_id}" BUILD_VERSION="${build_id}" \
    bash "${PROJECT_ROOT}/build.sh" "${build_id}"
}

function main() {
  local profile_list=''
  local profile=''
  local initial_reuse_rootfs="${REUSE_ROOTFS:-false}"
  local reuse_rootfs=''

  require_root
  validate_requested_image_profiles
  validate_reuse_rootfs_value "${initial_reuse_rootfs}"

  resolve_release_version
  resolve_build_id "${1:-}"
  resolve_artifact_version
  resolve_git_metadata

  profile_list="$(requested_image_profiles)"
  reuse_rootfs="${initial_reuse_rootfs}"

  status_line "Release version: ${RELEASE_VERSION}"
  status_line "Build ID: ${BUILD_ID}"
  status_line "Artifact version: ${ARTIFACT_VERSION}"
  status_line "Git commit: ${GIT_COMMIT}"
  status_line "Profiles: ${profile_list}"

  for profile in ${profile_list}; do
    run_profile_build "${profile}" "${reuse_rootfs}"
    reuse_rootfs='true'
  done
}

main "${1:-}"
