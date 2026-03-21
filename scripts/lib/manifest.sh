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

function current_rootfs_input_fingerprint() {
  {
    printf 'git_commit=%s\n' "${GIT_COMMIT}"
    printf 'blackarch_profile=%s\n' "${RESOLVED_BLACKARCH_PROFILE}"
    printf 'blackarch_packages=%s\n' "${BLACKARCH_PACKAGES:-}"
    printf 'blackarch_keyring_version=%s\n' "${RESOLVED_BLACKARCH_KEYRING_VERSION}"
    printf 'blackarch_keyring_sha256=%s\n' "${BLACKARCH_KEYRING_SHA256:-}"
    printf 'blackarch_bootstrap_mode=%s\n' "$(resolved_blackarch_bootstrap_mode)"
    printf 'blackarch_strap_url=%s\n' "${BLACKARCH_STRAP_URL:-}"
    printf 'blackarch_strap_sha256=%s\n' "${BLACKARCH_STRAP_SHA256:-}"
    printf 'image_hostname=%s\n' "${RESOLVED_IMAGE_HOSTNAME}"
    printf 'image_default_user=%s\n' "${RESOLVED_IMAGE_DEFAULT_USER}"
    printf 'image_default_user_gecos=%s\n' "${RESOLVED_IMAGE_DEFAULT_USER_GECOS}"
    printf 'image_locale=%s\n' "${RESOLVED_IMAGE_LOCALE}"
    printf 'image_timezone=%s\n' "${RESOLVED_IMAGE_TIMEZONE}"
    printf 'image_keymap=%s\n' "${RESOLVED_IMAGE_KEYMAP}"
    printf 'image_passwordless_sudo=%s\n' "${RESOLVED_IMAGE_PASSWORDLESS_SUDO}"
  } | sha256sum | awk '{print $1}'
}

function write_build_identity_manifest_entries() {
  local manifest_path="${1}"

  write_manifest_entry "${manifest_path}" "release_version" "${RELEASE_VERSION}"
  write_manifest_entry "${manifest_path}" "build_id" "${BUILD_ID}"
  write_manifest_entry "${manifest_path}" "artifact_version" "${ARTIFACT_VERSION}"
  write_manifest_entry "${manifest_path}" "git_commit" "${GIT_COMMIT}"
  write_manifest_entry "${manifest_path}" "git_tag" "${GIT_TAG}"
  write_manifest_entry "${manifest_path}" "built_at_utc" "$(current_timestamp_utc)"
}

function write_rootfs_configuration_manifest_entries() {
  local manifest_path="${1}"

  write_manifest_entry "${manifest_path}" "blackarch_profile" "${RESOLVED_BLACKARCH_PROFILE}"
  write_manifest_entry "${manifest_path}" "blackarch_packages" "${BLACKARCH_PACKAGES:-}"
  write_manifest_entry "${manifest_path}" "image_hostname" "${RESOLVED_IMAGE_HOSTNAME}"
  write_manifest_entry "${manifest_path}" "image_default_user" "${RESOLVED_IMAGE_DEFAULT_USER}"
  write_manifest_entry "${manifest_path}" "image_default_user_gecos" "${RESOLVED_IMAGE_DEFAULT_USER_GECOS}"
  write_manifest_entry "${manifest_path}" "image_locale" "${RESOLVED_IMAGE_LOCALE}"
  write_manifest_entry "${manifest_path}" "image_timezone" "${RESOLVED_IMAGE_TIMEZONE}"
  write_manifest_entry "${manifest_path}" "image_keymap" "${RESOLVED_IMAGE_KEYMAP}"
  write_manifest_entry "${manifest_path}" "image_passwordless_sudo" "${RESOLVED_IMAGE_PASSWORDLESS_SUDO}"
  write_manifest_entry "${manifest_path}" "blackarch_keyring_version" "${RESOLVED_BLACKARCH_KEYRING_VERSION}"
  write_manifest_entry "${manifest_path}" "blackarch_keyring_sha256" "${BLACKARCH_KEYRING_SHA256:-}"
  write_manifest_entry "${manifest_path}" "blackarch_keyring_sha256_source" "$(resolved_blackarch_keyring_sha256_source)"
  write_manifest_entry "${manifest_path}" "blackarch_bootstrap_mode" "$(resolved_blackarch_bootstrap_mode)"
  write_manifest_entry "${manifest_path}" "blackarch_strap_url" "${BLACKARCH_STRAP_URL:-}"
  write_manifest_entry "${manifest_path}" "blackarch_strap_sha256" "${BLACKARCH_STRAP_SHA256:-}"
  write_manifest_entry "${manifest_path}" "blackarch_strap_sha256_set" "$(resolved_blackarch_strap_sha256_set)"
  write_manifest_entry "${manifest_path}" "rootfs_input_fingerprint" "$(current_rootfs_input_fingerprint)"
}

function write_image_profile_manifest_entries() {
  local manifest_path="${1}"

  write_manifest_entry "${manifest_path}" "profile" "${RESOLVED_IMAGE_PROFILE}"
  write_manifest_entry "${manifest_path}" "filesystem" "${RESOLVED_IMAGE_ROOT_FS_TYPE}"
  write_manifest_entry "${manifest_path}" "boot_mode" "${RESOLVED_IMAGE_BOOT_MODE}"
  write_manifest_entry "${manifest_path}" "disk_size" "${RESOLVED_FINAL_DISK_SIZE}"
  write_manifest_entry "${manifest_path}" "profile_default_disk_size" "${RESOLVED_PROFILE_DEFAULT_DISK_SIZE}"
  write_manifest_entry "${manifest_path}" "efi_partition_size" "${RESOLVED_IMAGE_EFI_PARTITION_SIZE}"
  write_manifest_entry "${manifest_path}" "profile_pacman_packages" "${RESOLVED_PROFILE_PACMAN_PACKAGES}"
  write_manifest_entry "${manifest_path}" "profile_enable_systemd_units" "${RESOLVED_PROFILE_ENABLE_SYSTEMD_UNITS}"
  write_manifest_entry "${manifest_path}" "profile_disable_systemd_units" "${RESOLVED_PROFILE_DISABLE_SYSTEMD_UNITS}"
  write_manifest_entry "${manifest_path}" "image_enable_qemu_guest_agent" "${RESOLVED_IMAGE_ENABLE_QEMU_GUEST_AGENT}"
  write_manifest_entry "${manifest_path}" "image_swap_size" "${RESOLVED_IMAGE_SWAP_SIZE}"
}

function validate_reusable_rootfs_manifest() {
  local manifest_path="${1}"
  local expected_fingerprint=''

  if [ ! -r "${manifest_path}" ]; then
    printf 'Missing rootfs manifest: %s\n' "${manifest_path}" >&2
    return 1
  fi

  expected_fingerprint="$(current_rootfs_input_fingerprint)"

  (
    # shellcheck disable=SC1090
    source "${manifest_path}"

    if [ "${artifact_type:-}" != "rootfs" ]; then
      printf 'Existing rootfs manifest is not a rootfs manifest: %s\n' "${manifest_path}" >&2
      exit 1
    fi

    if [ "${artifact_name:-}" != "${ROOTFS_ARTIFACT_NAME}" ]; then
      printf 'Existing rootfs manifest has artifact_name=%s, expected %s\n' "${artifact_name:-missing}" "${ROOTFS_ARTIFACT_NAME}" >&2
      exit 1
    fi

    if [ "${release_version:-}" != "${RELEASE_VERSION}" ]; then
      printf 'Existing rootfs manifest has release_version=%s, expected %s\n' "${release_version:-missing}" "${RELEASE_VERSION}" >&2
      exit 1
    fi

    if [ "${build_id:-}" != "${BUILD_ID}" ]; then
      printf 'Existing rootfs manifest has build_id=%s, expected %s\n' "${build_id:-missing}" "${BUILD_ID}" >&2
      exit 1
    fi

    if [ "${artifact_version:-}" != "${ARTIFACT_VERSION}" ]; then
      printf 'Existing rootfs manifest has artifact_version=%s, expected %s\n' "${artifact_version:-missing}" "${ARTIFACT_VERSION}" >&2
      exit 1
    fi

    if [ "${git_commit:-}" != "${GIT_COMMIT}" ]; then
      printf 'Existing rootfs manifest has git_commit=%s, expected %s\n' "${git_commit:-missing}" "${GIT_COMMIT}" >&2
      exit 1
    fi

    if [ -z "${rootfs_input_fingerprint:-}" ]; then
      printf 'Existing rootfs manifest is missing rootfs_input_fingerprint: %s\n' "${manifest_path}" >&2
      exit 1
    fi

    if [ "${rootfs_input_fingerprint}" != "${expected_fingerprint}" ]; then
      printf 'Existing rootfs artifact is incompatible with the current Stage 1 configuration: %s\n' "${manifest_path}" >&2
      exit 1
    fi
  )
}

function write_rootfs_manifest() {
  : > "${ROOTFS_MANIFEST_PATH}"
  write_manifest_entry "${ROOTFS_MANIFEST_PATH}" "artifact_type" "rootfs"
  write_manifest_entry "${ROOTFS_MANIFEST_PATH}" "rootfs_name" "${ROOTFS_NAME_PREFIX}"
  write_manifest_entry "${ROOTFS_MANIFEST_PATH}" "artifact_name" "${ROOTFS_ARTIFACT_NAME}"
  write_manifest_entry "${ROOTFS_MANIFEST_PATH}" "artifact_format" "tar.zst"
  write_build_identity_manifest_entries "${ROOTFS_MANIFEST_PATH}"
  write_rootfs_configuration_manifest_entries "${ROOTFS_MANIFEST_PATH}"
}

function write_final_image_manifest() {
  : > "${FINAL_IMAGE_MANIFEST_PATH}"
  write_manifest_entry "${FINAL_IMAGE_MANIFEST_PATH}" "artifact_type" "image"
  write_manifest_entry "${FINAL_IMAGE_MANIFEST_PATH}" "image_name" "${RESOLVED_IMAGE_NAME_PREFIX}"
  write_manifest_entry "${FINAL_IMAGE_MANIFEST_PATH}" "artifact_name" "${FINAL_IMAGE_NAME}"
  write_manifest_entry "${FINAL_IMAGE_MANIFEST_PATH}" "artifact_format" "${RESOLVED_IMAGE_FINAL_FORMAT}"
  write_manifest_entry "${FINAL_IMAGE_MANIFEST_PATH}" "rootfs_artifact" "${ROOTFS_ARTIFACT_NAME}"
  write_build_identity_manifest_entries "${FINAL_IMAGE_MANIFEST_PATH}"
  write_rootfs_configuration_manifest_entries "${FINAL_IMAGE_MANIFEST_PATH}"
  write_image_profile_manifest_entries "${FINAL_IMAGE_MANIFEST_PATH}"
}
