#!/usr/bin/env bash

function write_manifest_entry() {
  local manifest_path="${1}"
  local key="${2}"
  local value="${3}"

  printf '%s=%q\n' "${key}" "${value}" >>"${manifest_path}"
}

function resolved_blackarch_bootstrap_mode() {
  if [ -n "${BLACKARCH_STRAP_URL:-}" ]; then
    printf '%s\n' 'legacy-custom-strap'
    return
  fi

  printf '%s\n' 'built-in'
}

function resolved_blackarch_keyring_sha256_source() {
  if [ -n "${BLACKARCH_KEYRING_SHA256:-}" ]; then
    printf '%s\n' 'env'
    return
  fi

  printf '%s\n' 'pinned'
}

function resolved_blackarch_strap_sha256_set() {
  if [ -n "${BLACKARCH_STRAP_SHA256:-}" ]; then
    printf '%s\n' 'true'
    return
  fi

  printf '%s\n' 'false'
}

function write_common_manifest_entries() {
  local manifest_path="${1}"

  write_manifest_entry "${manifest_path}" "BUILD_VERSION" "${BUILD_VERSION}"
  write_manifest_entry "${manifest_path}" "IMAGE_PROFILE" "${RESOLVED_IMAGE_PROFILE}"
  write_manifest_entry "${manifest_path}" "BLACKARCH_PROFILE" "${RESOLVED_BLACKARCH_PROFILE}"
  write_manifest_entry "${manifest_path}" "BLACKARCH_PACKAGES" "${BLACKARCH_PACKAGES:-}"
  write_manifest_entry "${manifest_path}" "DISK_SIZE" "${RESOLVED_FINAL_DISK_SIZE}"
  write_manifest_entry "${manifest_path}" "PROFILE_DEFAULT_DISK_SIZE" "${RESOLVED_PROFILE_DEFAULT_DISK_SIZE}"
  write_manifest_entry "${manifest_path}" "FINAL_FORMAT" "${RESOLVED_IMAGE_FINAL_FORMAT}"
  write_manifest_entry "${manifest_path}" "BOOT_MODE" "${RESOLVED_IMAGE_BOOT_MODE}"
  write_manifest_entry "${manifest_path}" "EFI_PARTITION_SIZE" "${RESOLVED_IMAGE_EFI_PARTITION_SIZE}"
  write_manifest_entry "${manifest_path}" "ROOT_FS_TYPE" "${RESOLVED_IMAGE_ROOT_FS_TYPE}"
  write_manifest_entry "${manifest_path}" "PROFILE_PACMAN_PACKAGES" "${RESOLVED_PROFILE_PACMAN_PACKAGES}"
  write_manifest_entry "${manifest_path}" "PROFILE_ENABLE_SYSTEMD_UNITS" "${RESOLVED_PROFILE_ENABLE_SYSTEMD_UNITS}"
  write_manifest_entry "${manifest_path}" "PROFILE_DISABLE_SYSTEMD_UNITS" "${RESOLVED_PROFILE_DISABLE_SYSTEMD_UNITS}"
  write_manifest_entry "${manifest_path}" "IMAGE_ENABLE_QEMU_GUEST_AGENT" "${RESOLVED_IMAGE_ENABLE_QEMU_GUEST_AGENT}"
  write_manifest_entry "${manifest_path}" "IMAGE_HOSTNAME" "${RESOLVED_IMAGE_HOSTNAME}"
  write_manifest_entry "${manifest_path}" "IMAGE_DEFAULT_USER" "${RESOLVED_IMAGE_DEFAULT_USER}"
  write_manifest_entry "${manifest_path}" "IMAGE_DEFAULT_USER_GECOS" "${RESOLVED_IMAGE_DEFAULT_USER_GECOS}"
  write_manifest_entry "${manifest_path}" "IMAGE_LOCALE" "${RESOLVED_IMAGE_LOCALE}"
  write_manifest_entry "${manifest_path}" "IMAGE_TIMEZONE" "${RESOLVED_IMAGE_TIMEZONE}"
  write_manifest_entry "${manifest_path}" "IMAGE_KEYMAP" "${RESOLVED_IMAGE_KEYMAP}"
  write_manifest_entry "${manifest_path}" "IMAGE_SWAP_SIZE" "${RESOLVED_IMAGE_SWAP_SIZE}"
  write_manifest_entry "${manifest_path}" "IMAGE_PASSWORDLESS_SUDO" "${RESOLVED_IMAGE_PASSWORDLESS_SUDO}"
  write_manifest_entry "${manifest_path}" "BLACKARCH_KEYRING_VERSION" "${RESOLVED_BLACKARCH_KEYRING_VERSION}"
  write_manifest_entry "${manifest_path}" "BLACKARCH_KEYRING_SHA256_SOURCE" "$(resolved_blackarch_keyring_sha256_source)"
  write_manifest_entry "${manifest_path}" "BLACKARCH_BOOTSTRAP_MODE" "$(resolved_blackarch_bootstrap_mode)"
  write_manifest_entry "${manifest_path}" "BLACKARCH_STRAP_URL" "${BLACKARCH_STRAP_URL:-}"
  write_manifest_entry "${manifest_path}" "BLACKARCH_STRAP_SHA256_SET" "$(resolved_blackarch_strap_sha256_set)"
  write_manifest_entry "${manifest_path}" "TIMESTAMP_UTC" "$(current_timestamp_utc)"
}

function write_rootfs_manifest() {
  : > "${ROOTFS_MANIFEST_PATH}"
  write_manifest_entry "${ROOTFS_MANIFEST_PATH}" "ARTIFACT_TYPE" "rootfs"
  write_manifest_entry "${ROOTFS_MANIFEST_PATH}" "ARTIFACT_NAME" "$(basename "${ROOTFS_ARTIFACT_PATH}")"
  write_manifest_entry "${ROOTFS_MANIFEST_PATH}" "ARTIFACT_FORMAT" "tar.zst"
  write_common_manifest_entries "${ROOTFS_MANIFEST_PATH}"
}

function write_final_image_manifest() {
  : > "${FINAL_IMAGE_MANIFEST_PATH}"
  write_manifest_entry "${FINAL_IMAGE_MANIFEST_PATH}" "ARTIFACT_TYPE" "image"
  write_manifest_entry "${FINAL_IMAGE_MANIFEST_PATH}" "ARTIFACT_NAME" "$(basename "${FINAL_IMAGE_PATH}")"
  write_manifest_entry "${FINAL_IMAGE_MANIFEST_PATH}" "ARTIFACT_FORMAT" "${RESOLVED_IMAGE_FINAL_FORMAT}"
  write_manifest_entry "${FINAL_IMAGE_MANIFEST_PATH}" "ROOTFS_ARTIFACT" "$(basename "${ROOTFS_ARTIFACT_PATH}")"
  write_common_manifest_entries "${FINAL_IMAGE_MANIFEST_PATH}"
}
