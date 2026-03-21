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

  write_manifest_entry "${manifest_path}" "release_version" "${RELEASE_VERSION}"
  write_manifest_entry "${manifest_path}" "build_id" "${BUILD_ID}"
  write_manifest_entry "${manifest_path}" "artifact_version" "${ARTIFACT_VERSION}"
  write_manifest_entry "${manifest_path}" "git_commit" "${GIT_COMMIT}"
  write_manifest_entry "${manifest_path}" "git_tag" "${GIT_TAG}"
  write_manifest_entry "${manifest_path}" "profile" "${RESOLVED_IMAGE_PROFILE}"
  write_manifest_entry "${manifest_path}" "filesystem" "${RESOLVED_IMAGE_ROOT_FS_TYPE}"
  write_manifest_entry "${manifest_path}" "boot_mode" "${RESOLVED_IMAGE_BOOT_MODE}"
  write_manifest_entry "${manifest_path}" "blackarch_profile" "${RESOLVED_BLACKARCH_PROFILE}"
  write_manifest_entry "${manifest_path}" "blackarch_packages" "${BLACKARCH_PACKAGES:-}"
  write_manifest_entry "${manifest_path}" "disk_size" "${RESOLVED_FINAL_DISK_SIZE}"
  write_manifest_entry "${manifest_path}" "profile_default_disk_size" "${RESOLVED_PROFILE_DEFAULT_DISK_SIZE}"
  write_manifest_entry "${manifest_path}" "efi_partition_size" "${RESOLVED_IMAGE_EFI_PARTITION_SIZE}"
  write_manifest_entry "${manifest_path}" "profile_pacman_packages" "${RESOLVED_PROFILE_PACMAN_PACKAGES}"
  write_manifest_entry "${manifest_path}" "profile_enable_systemd_units" "${RESOLVED_PROFILE_ENABLE_SYSTEMD_UNITS}"
  write_manifest_entry "${manifest_path}" "profile_disable_systemd_units" "${RESOLVED_PROFILE_DISABLE_SYSTEMD_UNITS}"
  write_manifest_entry "${manifest_path}" "image_enable_qemu_guest_agent" "${RESOLVED_IMAGE_ENABLE_QEMU_GUEST_AGENT}"
  write_manifest_entry "${manifest_path}" "image_hostname" "${RESOLVED_IMAGE_HOSTNAME}"
  write_manifest_entry "${manifest_path}" "image_default_user" "${RESOLVED_IMAGE_DEFAULT_USER}"
  write_manifest_entry "${manifest_path}" "image_default_user_gecos" "${RESOLVED_IMAGE_DEFAULT_USER_GECOS}"
  write_manifest_entry "${manifest_path}" "image_locale" "${RESOLVED_IMAGE_LOCALE}"
  write_manifest_entry "${manifest_path}" "image_timezone" "${RESOLVED_IMAGE_TIMEZONE}"
  write_manifest_entry "${manifest_path}" "image_keymap" "${RESOLVED_IMAGE_KEYMAP}"
  write_manifest_entry "${manifest_path}" "image_swap_size" "${RESOLVED_IMAGE_SWAP_SIZE}"
  write_manifest_entry "${manifest_path}" "image_passwordless_sudo" "${RESOLVED_IMAGE_PASSWORDLESS_SUDO}"
  write_manifest_entry "${manifest_path}" "blackarch_keyring_version" "${RESOLVED_BLACKARCH_KEYRING_VERSION}"
  write_manifest_entry "${manifest_path}" "blackarch_keyring_sha256_source" "$(resolved_blackarch_keyring_sha256_source)"
  write_manifest_entry "${manifest_path}" "blackarch_bootstrap_mode" "$(resolved_blackarch_bootstrap_mode)"
  write_manifest_entry "${manifest_path}" "blackarch_strap_url" "${BLACKARCH_STRAP_URL:-}"
  write_manifest_entry "${manifest_path}" "blackarch_strap_sha256_set" "$(resolved_blackarch_strap_sha256_set)"
  write_manifest_entry "${manifest_path}" "built_at_utc" "$(current_timestamp_utc)"
}

function write_rootfs_manifest() {
  : > "${ROOTFS_MANIFEST_PATH}"
  write_manifest_entry "${ROOTFS_MANIFEST_PATH}" "artifact_type" "rootfs"
  write_manifest_entry "${ROOTFS_MANIFEST_PATH}" "rootfs_name" "${ROOTFS_NAME_PREFIX}"
  write_manifest_entry "${ROOTFS_MANIFEST_PATH}" "artifact_name" "${ROOTFS_ARTIFACT_NAME}"
  write_manifest_entry "${ROOTFS_MANIFEST_PATH}" "artifact_format" "tar.zst"
  write_common_manifest_entries "${ROOTFS_MANIFEST_PATH}"
}

function write_final_image_manifest() {
  : > "${FINAL_IMAGE_MANIFEST_PATH}"
  write_manifest_entry "${FINAL_IMAGE_MANIFEST_PATH}" "artifact_type" "image"
  write_manifest_entry "${FINAL_IMAGE_MANIFEST_PATH}" "image_name" "${RESOLVED_IMAGE_NAME_PREFIX}"
  write_manifest_entry "${FINAL_IMAGE_MANIFEST_PATH}" "artifact_name" "${FINAL_IMAGE_NAME}"
  write_manifest_entry "${FINAL_IMAGE_MANIFEST_PATH}" "artifact_format" "${RESOLVED_IMAGE_FINAL_FORMAT}"
  write_manifest_entry "${FINAL_IMAGE_MANIFEST_PATH}" "rootfs_artifact" "${ROOTFS_ARTIFACT_NAME}"
  write_common_manifest_entries "${FINAL_IMAGE_MANIFEST_PATH}"
}
