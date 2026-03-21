#!/usr/bin/env bash

function apply_profile_rootfs_overlay() {
  if [ -z "${RESOLVED_PROFILE_ROOTFS_OVERLAY_DIR:-}" ]; then
    return 0
  fi

  # Preserve file metadata from the overlay, but never leak the build host's
  # uid/gid from the checked-out repo into the target image.
  run_logged cp -a --no-preserve=ownership "${RESOLVED_PROFILE_ROOTFS_OVERLAY_DIR}/." "${TARGET_ROOT}/"
}

function reset_profile_rootfs_ownership() {
  run_logged chown root:root "${TARGET_ROOT}"
  run_logged chown root:root "${TARGET_ROOT}/etc"
  run_logged chown -R root:root "${TARGET_ROOT}/etc/cloud"
}

function validate_root_owned_path() {
  local target_path="${1}"
  local ownership=''

  if [ ! -e "${target_path}" ]; then
    printf 'Required path is missing from target image: %s\n' "${target_path}" >&2
    return 1
  fi

  ownership="$(stat -c '%u:%g' "${target_path}")"

  if [ "${ownership}" != "0:0" ]; then
    printf 'Required path is not owned by root:root (%s): %s\n' "${ownership}" "${target_path}" >&2
    return 1
  fi
}

function validate_profile_rootfs_ownership() {
  validate_root_owned_path "${TARGET_ROOT}"
  validate_root_owned_path "${TARGET_ROOT}/etc"
  validate_root_owned_path "${TARGET_ROOT}/etc/cloud"
  validate_root_owned_path "${TARGET_ROOT}/etc/cloud/cloud.cfg.d"
}

function install_profile_pacman_packages() {
  local -a profile_packages=()

  if [ -z "${RESOLVED_PROFILE_PACMAN_PACKAGES:-}" ]; then
    return 0
  fi

  read -r -a profile_packages <<<"${RESOLVED_PROFILE_PACMAN_PACKAGES}"

  if [ "${#profile_packages[@]}" -eq 0 ]; then
    return 0
  fi

  run_logged arch-chroot "${TARGET_ROOT}" /usr/bin/pacman -S --noconfirm --needed --noprogressbar --color never "${profile_packages[@]}"
}

function enable_profile_systemd_units() {
  local -a profile_units=()

  if [ -z "${RESOLVED_PROFILE_ENABLE_SYSTEMD_UNITS:-}" ]; then
    return 0
  fi

  read -r -a profile_units <<<"${RESOLVED_PROFILE_ENABLE_SYSTEMD_UNITS}"

  if [ "${#profile_units[@]}" -eq 0 ]; then
    return 0
  fi

  run_logged arch-chroot "${TARGET_ROOT}" /usr/bin/systemctl --quiet enable "${profile_units[@]}"
}

function disable_profile_systemd_units() {
  local -a profile_units=()
  local unit=''

  if [ -z "${RESOLVED_PROFILE_DISABLE_SYSTEMD_UNITS:-}" ]; then
    return 0
  fi

  read -r -a profile_units <<<"${RESOLVED_PROFILE_DISABLE_SYSTEMD_UNITS}"

  for unit in "${profile_units[@]}"; do
    log_command arch-chroot "${TARGET_ROOT}" /usr/bin/systemctl --quiet disable "${unit}"
    arch-chroot "${TARGET_ROOT}" /usr/bin/systemctl --quiet disable "${unit}" >/dev/null 2>&1 || true
  done
}

function run_profile_hook() {
  local hook_name="${1}"

  if [ -z "${RESOLVED_PROFILE_HOOK_SCRIPT:-}" ]; then
    return 0
  fi

  unset -f profile_hook || true
  # shellcheck disable=SC1090
  source "${RESOLVED_PROFILE_HOOK_SCRIPT}"

  if ! declare -F profile_hook >/dev/null 2>&1; then
    printf 'Profile hook script did not define profile_hook: %s\n' "${RESOLVED_PROFILE_HOOK_SCRIPT}" >&2
    return 1
  fi

  status_line "Running profile hook '${hook_name}' from ${RESOLVED_PROFILE_HOOK_SCRIPT}"
  profile_hook "${hook_name}"
}
