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

function resolve_profile_path() {
  local requested_path="${1:-}"

  if [ -z "${requested_path}" ]; then
    return 0
  fi

  if [[ "${requested_path}" = /* ]]; then
    printf '%s\n' "${requested_path}"
    return 0
  fi

  printf '%s\n' "${PROFILES_DIR}/${requested_path}"
}

function word_list_contains() {
  local word_list="${1:-}"
  local needle="${2}"
  local -a entries=()
  local entry=''

  read -r -a entries <<<"${word_list}"

  for entry in "${entries[@]}"; do
    if [ "${entry}" = "${needle}" ]; then
      return 0
    fi
  done

  return 1
}

function append_word_to_list() {
  local word_list="${1:-}"
  local word="${2}"

  if word_list_contains "${word_list}" "${word}"; then
    printf '%s\n' "${word_list}"
    return 0
  fi

  if [ -z "${word_list}" ]; then
    printf '%s\n' "${word}"
    return 0
  fi

  printf '%s %s\n' "${word_list}" "${word}"
}

function remove_word_from_list() {
  local word_list="${1:-}"
  local word="${2}"
  local -a entries=()
  local -a remaining_entries=()
  local entry=''

  read -r -a entries <<<"${word_list}"

  for entry in "${entries[@]}"; do
    if [ "${entry}" != "${word}" ]; then
      remaining_entries+=("${entry}")
    fi
  done

  printf '%s\n' "${remaining_entries[*]}"
}

function load_image_profile() {
  local requested_profile="${IMAGE_PROFILE:-generic-qemu}"
  local profile_path="${PROFILES_DIR}/${requested_profile}.env"
  local resolved_overlay_dir=''
  local resolved_hook_script=''
  local resolved_profile_pacman_packages=''
  local resolved_profile_enable_systemd_units=''
  local resolved_profile_disable_systemd_units=''

  validate_image_profile_value "${requested_profile}" || return 1

  if [ ! -r "${profile_path}" ]; then
    printf 'Unsupported IMAGE_PROFILE: %s\n' "${requested_profile}" >&2
    return 1
  fi

  unset PROFILE_ID PROFILE_NAME_SUFFIX PROFILE_FINAL_FORMAT PROFILE_ROOT_FS_TYPE PROFILE_DEFAULT_DISK_SIZE PROFILE_BOOT_MODE PROFILE_EFI_PARTITION_SIZE PROFILE_PACMAN_PACKAGES PROFILE_ENABLE_SYSTEMD_UNITS PROFILE_DISABLE_SYSTEMD_UNITS PROFILE_ROOTFS_OVERLAY_DIR PROFILE_HOOK_SCRIPT PROFILE_ENABLE_QEMU_GUEST_AGENT
  # shellcheck disable=SC1090
  source "${profile_path}"

  if [ -z "${PROFILE_ID:-}" ] || [ -z "${PROFILE_NAME_SUFFIX:-}" ] || [ -z "${PROFILE_FINAL_FORMAT:-}" ] || [ -z "${PROFILE_ROOT_FS_TYPE:-}" ] || [ -z "${PROFILE_DEFAULT_DISK_SIZE:-}" ]; then
    printf 'Profile file is missing required settings: %s\n' "${profile_path}" >&2
    return 1
  fi

  PROFILE_BOOT_MODE="${PROFILE_BOOT_MODE:-bios+uefi}"
  PROFILE_EFI_PARTITION_SIZE="${PROFILE_EFI_PARTITION_SIZE:-}"
  PROFILE_PACMAN_PACKAGES="${PROFILE_PACMAN_PACKAGES:-}"
  PROFILE_ENABLE_SYSTEMD_UNITS="${PROFILE_ENABLE_SYSTEMD_UNITS:-}"
  PROFILE_DISABLE_SYSTEMD_UNITS="${PROFILE_DISABLE_SYSTEMD_UNITS:-}"
  PROFILE_ROOTFS_OVERLAY_DIR="${PROFILE_ROOTFS_OVERLAY_DIR:-}"
  PROFILE_HOOK_SCRIPT="${PROFILE_HOOK_SCRIPT:-}"

  validate_final_format_value "${PROFILE_FINAL_FORMAT}" || return 1
  validate_root_fs_type_value "${PROFILE_ROOT_FS_TYPE}" || return 1
  validate_size_value "PROFILE_DEFAULT_DISK_SIZE" "${PROFILE_DEFAULT_DISK_SIZE}" || return 1
  validate_boot_mode_value "${PROFILE_BOOT_MODE}" || return 1

  case "${PROFILE_BOOT_MODE}" in
    bios)
      if [ -n "${PROFILE_EFI_PARTITION_SIZE}" ]; then
        printf 'PROFILE_EFI_PARTITION_SIZE must be empty when PROFILE_BOOT_MODE=bios\n' >&2
        return 1
      fi
      ;;
    bios+uefi)
      PROFILE_EFI_PARTITION_SIZE="${PROFILE_EFI_PARTITION_SIZE:-300M}"
      validate_partition_size_value "PROFILE_EFI_PARTITION_SIZE" "${PROFILE_EFI_PARTITION_SIZE}" || return 1
      ;;
  esac

  if [ -n "${PROFILE_ROOTFS_OVERLAY_DIR}" ]; then
    resolved_overlay_dir="$(resolve_profile_path "${PROFILE_ROOTFS_OVERLAY_DIR}")"
  elif [ -d "${PROFILES_DIR}/${PROFILE_ID}/rootfs-overlay" ]; then
    resolved_overlay_dir="${PROFILES_DIR}/${PROFILE_ID}/rootfs-overlay"
  fi

  if [ -n "${resolved_overlay_dir}" ] && [ ! -d "${resolved_overlay_dir}" ]; then
    printf 'Missing profile overlay directory: %s\n' "${resolved_overlay_dir}" >&2
    return 1
  fi

  if [ -n "${PROFILE_HOOK_SCRIPT}" ]; then
    resolved_hook_script="$(resolve_profile_path "${PROFILE_HOOK_SCRIPT}")"
  elif [ -r "${PROFILES_DIR}/${PROFILE_ID}.sh" ]; then
    resolved_hook_script="${PROFILES_DIR}/${PROFILE_ID}.sh"
  fi

  if [ -n "${resolved_hook_script}" ] && [ ! -r "${resolved_hook_script}" ]; then
    printf 'Missing profile hook script: %s\n' "${resolved_hook_script}" >&2
    return 1
  fi

  resolved_profile_pacman_packages="${PROFILE_PACMAN_PACKAGES}"
  resolved_profile_enable_systemd_units="${PROFILE_ENABLE_SYSTEMD_UNITS}"
  resolved_profile_disable_systemd_units="${PROFILE_DISABLE_SYSTEMD_UNITS}"

  if [ -n "${PROFILE_ENABLE_QEMU_GUEST_AGENT:-}" ] && [ -z "${IMAGE_ENABLE_QEMU_GUEST_AGENT:-}" ]; then
    IMAGE_ENABLE_QEMU_GUEST_AGENT="${PROFILE_ENABLE_QEMU_GUEST_AGENT}"
    export IMAGE_ENABLE_QEMU_GUEST_AGENT
  fi

  if [ -n "${IMAGE_ENABLE_QEMU_GUEST_AGENT:-}" ]; then
    case "${IMAGE_ENABLE_QEMU_GUEST_AGENT}" in
      true)
        resolved_profile_pacman_packages="$(append_word_to_list "${resolved_profile_pacman_packages}" "qemu-guest-agent")"
        resolved_profile_enable_systemd_units="$(append_word_to_list "${resolved_profile_enable_systemd_units}" "qemu-guest-agent.service")"
        resolved_profile_disable_systemd_units="$(remove_word_from_list "${resolved_profile_disable_systemd_units}" "qemu-guest-agent.service")"
        ;;
      false)
        resolved_profile_pacman_packages="$(remove_word_from_list "${resolved_profile_pacman_packages}" "qemu-guest-agent")"
        resolved_profile_enable_systemd_units="$(remove_word_from_list "${resolved_profile_enable_systemd_units}" "qemu-guest-agent.service")"
        resolved_profile_disable_systemd_units="$(append_word_to_list "${resolved_profile_disable_systemd_units}" "qemu-guest-agent.service")"
        ;;
    esac
  fi

  RESOLVED_IMAGE_PROFILE="${PROFILE_ID}"
  RESOLVED_IMAGE_FINAL_FORMAT="${PROFILE_FINAL_FORMAT}"
  RESOLVED_IMAGE_BOOT_MODE="${PROFILE_BOOT_MODE}"
  RESOLVED_IMAGE_EFI_PARTITION_SIZE="${PROFILE_EFI_PARTITION_SIZE}"
  RESOLVED_IMAGE_ROOT_FS_TYPE="${PROFILE_ROOT_FS_TYPE}"
  RESOLVED_PROFILE_DEFAULT_DISK_SIZE="${PROFILE_DEFAULT_DISK_SIZE}"
  RESOLVED_PROFILE_PACMAN_PACKAGES="${resolved_profile_pacman_packages}"
  RESOLVED_PROFILE_ENABLE_SYSTEMD_UNITS="${resolved_profile_enable_systemd_units}"
  RESOLVED_PROFILE_DISABLE_SYSTEMD_UNITS="${resolved_profile_disable_systemd_units}"
  RESOLVED_PROFILE_ROOTFS_OVERLAY_DIR="${resolved_overlay_dir}"
  RESOLVED_PROFILE_HOOK_SCRIPT="${resolved_hook_script}"

  if word_list_contains "${RESOLVED_PROFILE_PACMAN_PACKAGES}" "qemu-guest-agent" \
    || word_list_contains "${RESOLVED_PROFILE_ENABLE_SYSTEMD_UNITS}" "qemu-guest-agent.service"; then
    RESOLVED_IMAGE_ENABLE_QEMU_GUEST_AGENT="true"
  else
    RESOLVED_IMAGE_ENABLE_QEMU_GUEST_AGENT="false"
  fi

  RESOLVED_IMAGE_NAME_PREFIX="${IMAGE_NAME_PREFIX}-${PROFILE_NAME_SUFFIX}"
  export RESOLVED_IMAGE_PROFILE
  export RESOLVED_IMAGE_FINAL_FORMAT
  export RESOLVED_IMAGE_ENABLE_QEMU_GUEST_AGENT
  export RESOLVED_IMAGE_BOOT_MODE
  export RESOLVED_IMAGE_EFI_PARTITION_SIZE
  export RESOLVED_IMAGE_ROOT_FS_TYPE
  export RESOLVED_PROFILE_DEFAULT_DISK_SIZE
  export RESOLVED_PROFILE_PACMAN_PACKAGES
  export RESOLVED_PROFILE_ENABLE_SYSTEMD_UNITS
  export RESOLVED_PROFILE_DISABLE_SYSTEMD_UNITS
  export RESOLVED_PROFILE_ROOTFS_OVERLAY_DIR
  export RESOLVED_PROFILE_HOOK_SCRIPT
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
  export RESOLVED_IMAGE_BOOT_MODE
  export RESOLVED_IMAGE_EFI_PARTITION_SIZE
  export RESOLVED_IMAGE_ROOT_FS_TYPE
  export RESOLVED_PROFILE_DEFAULT_DISK_SIZE
  export RESOLVED_PROFILE_PACMAN_PACKAGES
  export RESOLVED_PROFILE_ENABLE_SYSTEMD_UNITS
  export RESOLVED_PROFILE_DISABLE_SYSTEMD_UNITS
  export RESOLVED_PROFILE_ROOTFS_OVERLAY_DIR
  export RESOLVED_PROFILE_HOOK_SCRIPT
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
