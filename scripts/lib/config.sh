#!/usr/bin/env bash

: "${LIB_DIR:=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
readonly LIB_DIR
: "${PROJECT_ROOT:=$(cd "${LIB_DIR}/../.." && pwd)}"
readonly PROJECT_ROOT
: "${OUTPUT_ROOT:=${PROJECT_ROOT}/output}"
readonly OUTPUT_ROOT
: "${ROOTFS_OUTPUT_DIR:=${OUTPUT_ROOT}/rootfs}"
readonly ROOTFS_OUTPUT_DIR
: "${IMAGE_OUTPUT_DIR:=${OUTPUT_ROOT}/images}"
readonly IMAGE_OUTPUT_DIR
: "${TMP_ROOT:=${PROJECT_ROOT}/tmp}"
readonly TMP_ROOT
: "${PROFILES_DIR:=${PROJECT_ROOT}/profiles}"
readonly PROFILES_DIR
: "${ROOTFS_NAME_PREFIX:=blackarch-rootfs}"
readonly ROOTFS_NAME_PREFIX
: "${IMAGE_NAME_PREFIX:=BlackArch-Linux-x86_64}"
readonly IMAGE_NAME_PREFIX

# shellcheck source=scripts/lib/validation.sh
source "${LIB_DIR}/validation.sh"

function next_default_build_version() {
  local build_date=''
  local file_name=''
  local release=''
  local max_release=-1
  local path=''

  build_date="$(date +%Y%m%d)"

  if [ -d "${OUTPUT_ROOT}" ]; then
    shopt -s nullglob

    for path in "${ROOTFS_OUTPUT_DIR}"/* "${IMAGE_OUTPUT_DIR}"/*; do
      file_name="$(basename "${path}")"

      if [[ "${file_name}" =~ -${build_date}\.([0-9]+)(\.|$) ]]; then
        release="${BASH_REMATCH[1]}"

        if [ "${release}" -gt "${max_release}" ]; then
          max_release="${release}"
        fi
      fi
    done

    shopt -u nullglob
  fi

  printf '%s.%s\n' "${build_date}" "$((max_release + 1))"
}

function resolve_build_version() {
  if [ -n "${1:-}" ]; then
    BUILD_VERSION="${1}"
    BUILD_VERSION_WAS_DEFAULTED=0
  elif [ -n "${BUILD_VERSION:-}" ]; then
    BUILD_VERSION_WAS_DEFAULTED=0
  else
    BUILD_VERSION="$(next_default_build_version)"
    BUILD_VERSION_WAS_DEFAULTED=1
  fi

  export BUILD_VERSION
  export BUILD_VERSION_WAS_DEFAULTED
}

function load_image_profile() {
  local requested_profile="${IMAGE_PROFILE:-generic-qemu}"
  local profile_path="${PROFILES_DIR}/${requested_profile}.env"

  validate_image_profile_value "${requested_profile}"

  if [ ! -r "${profile_path}" ]; then
    printf 'Unsupported IMAGE_PROFILE: %s\n' "${requested_profile}" >&2
    return 1
  fi

  unset PROFILE_ID PROFILE_FINAL_FORMAT PROFILE_ENABLE_QEMU_GUEST_AGENT PROFILE_NAME_SUFFIX PROFILE_ROOT_FS_TYPE PROFILE_DEFAULT_DISK_SIZE
  # shellcheck disable=SC1090
  source "${profile_path}"

  validate_root_fs_type_value "${PROFILE_ROOT_FS_TYPE}"
  validate_size_value "PROFILE_DEFAULT_DISK_SIZE" "${PROFILE_DEFAULT_DISK_SIZE}"

  RESOLVED_IMAGE_PROFILE="${PROFILE_ID}"
  RESOLVED_IMAGE_FINAL_FORMAT="${PROFILE_FINAL_FORMAT}"
  RESOLVED_IMAGE_ROOT_FS_TYPE="${PROFILE_ROOT_FS_TYPE}"
  RESOLVED_PROFILE_DEFAULT_DISK_SIZE="${PROFILE_DEFAULT_DISK_SIZE}"

  if [ -n "${IMAGE_ENABLE_QEMU_GUEST_AGENT:-}" ]; then
    RESOLVED_IMAGE_ENABLE_QEMU_GUEST_AGENT="${IMAGE_ENABLE_QEMU_GUEST_AGENT}"
  else
    RESOLVED_IMAGE_ENABLE_QEMU_GUEST_AGENT="${PROFILE_ENABLE_QEMU_GUEST_AGENT}"
  fi

  RESOLVED_IMAGE_NAME_PREFIX="${IMAGE_NAME_PREFIX}-${PROFILE_NAME_SUFFIX}"
  export RESOLVED_IMAGE_PROFILE
  export RESOLVED_IMAGE_FINAL_FORMAT
  export RESOLVED_IMAGE_ENABLE_QEMU_GUEST_AGENT
  export RESOLVED_IMAGE_ROOT_FS_TYPE
  export RESOLVED_PROFILE_DEFAULT_DISK_SIZE
  export RESOLVED_IMAGE_NAME_PREFIX
}

function resolve_build_context() {
  resolve_build_version "${1:-}"
  load_image_profile

  RESOLVED_BLACKARCH_PROFILE="${BLACKARCH_PROFILE:-core}"
  RESOLVED_BLACKARCH_KEYRING_VERSION="${BLACKARCH_KEYRING_VERSION:-${DEFAULT_BLACKARCH_KEYRING_VERSION}}"
  RESOLVED_FINAL_DISK_SIZE="${DISK_SIZE:-${DEFAULT_DISK_SIZE:-${RESOLVED_PROFILE_DEFAULT_DISK_SIZE}}}"
  RESOLVED_IMAGE_HOSTNAME="${IMAGE_HOSTNAME:-blackarch}"
  RESOLVED_IMAGE_SWAP_SIZE="${IMAGE_SWAP_SIZE:-512m}"
  RESOLVED_IMAGE_LOCALE="${IMAGE_LOCALE:-C.UTF-8}"
  RESOLVED_IMAGE_TIMEZONE="${IMAGE_TIMEZONE:-UTC}"
  RESOLVED_IMAGE_KEYMAP="${IMAGE_KEYMAP:-us}"
  RESOLVED_IMAGE_DEFAULT_USER="${IMAGE_DEFAULT_USER:-arch}"
  RESOLVED_IMAGE_DEFAULT_USER_GECOS="${IMAGE_DEFAULT_USER_GECOS:-BlackArch Cloud User}"
  RESOLVED_IMAGE_PASSWORDLESS_SUDO="${IMAGE_PASSWORDLESS_SUDO:-true}"
  ROOTFS_ARTIFACT_PATH="${ROOTFS_OUTPUT_DIR}/${ROOTFS_NAME_PREFIX}-${BUILD_VERSION}.tar.zst"
  ROOTFS_MANIFEST_PATH="${ROOTFS_OUTPUT_DIR}/${ROOTFS_NAME_PREFIX}-${BUILD_VERSION}.manifest"
  BUILD_WORKDIR="${BUILD_WORKDIR:-${TMP_ROOT}/build-${BUILD_VERSION}-${RESOLVED_IMAGE_PROFILE}}"
  STAGING_IMAGE_PATH="${BUILD_WORKDIR}/${RESOLVED_IMAGE_NAME_PREFIX}-${BUILD_VERSION}.raw"
  FINAL_IMAGE_PATH="${IMAGE_OUTPUT_DIR}/${RESOLVED_IMAGE_NAME_PREFIX}-${BUILD_VERSION}.${RESOLVED_IMAGE_FINAL_FORMAT}"
  FINAL_IMAGE_MANIFEST_PATH="${IMAGE_OUTPUT_DIR}/${RESOLVED_IMAGE_NAME_PREFIX}-${BUILD_VERSION}.manifest"
  FINAL_IMAGE_CHECKSUM_PATH="${FINAL_IMAGE_PATH}.SHA256"

  export IMAGE_PROFILE="${RESOLVED_IMAGE_PROFILE}"
  export IMAGE_ENABLE_QEMU_GUEST_AGENT="${RESOLVED_IMAGE_ENABLE_QEMU_GUEST_AGENT}"
  export RESOLVED_BLACKARCH_PROFILE
  export RESOLVED_BLACKARCH_KEYRING_VERSION
  export RESOLVED_FINAL_DISK_SIZE
  export RESOLVED_IMAGE_ROOT_FS_TYPE
  export RESOLVED_PROFILE_DEFAULT_DISK_SIZE
  export RESOLVED_IMAGE_HOSTNAME
  export RESOLVED_IMAGE_SWAP_SIZE
  export RESOLVED_IMAGE_LOCALE
  export RESOLVED_IMAGE_TIMEZONE
  export RESOLVED_IMAGE_KEYMAP
  export RESOLVED_IMAGE_DEFAULT_USER
  export RESOLVED_IMAGE_DEFAULT_USER_GECOS
  export RESOLVED_IMAGE_PASSWORDLESS_SUDO
  export ROOTFS_ARTIFACT_PATH
  export ROOTFS_MANIFEST_PATH
  export BUILD_WORKDIR
  export STAGING_IMAGE_PATH
  export FINAL_IMAGE_PATH
  export FINAL_IMAGE_MANIFEST_PATH
  export FINAL_IMAGE_CHECKSUM_PATH

  validate_build_configuration "${BUILD_VERSION}"
}
