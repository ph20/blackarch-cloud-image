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

function image_user_sudo_policy() {
  case "${RESOLVED_IMAGE_PASSWORDLESS_SUDO}" in
    true)
      printf '%s\n' 'ALL=(ALL) NOPASSWD:ALL'
      ;;
    false)
      printf '%s\n' 'ALL=(ALL) ALL'
      ;;
  esac
}

function ensure_local_image_user() {
  local user_name="${1}"
  local gecos="${2}"
  local user_groups="${3}"

  if arch-chroot "${TARGET_ROOT}" /usr/bin/id -u "${user_name}" >/dev/null 2>&1; then
    run_logged arch-chroot "${TARGET_ROOT}" /usr/bin/usermod -c "${gecos}" -s /bin/bash -aG "${user_groups}" "${user_name}"
    return 0
  fi

  run_logged arch-chroot "${TARGET_ROOT}" /usr/bin/useradd -m -U -c "${gecos}" -G "${user_groups}" -s /bin/bash "${user_name}"
}

function resolved_target_user_home() {
  local user_name="${1}"
  local passwd_entry=''

  passwd_entry="$(arch-chroot "${TARGET_ROOT}" /usr/bin/getent passwd "${user_name}")" || return 1
  printf '%s\n' "${passwd_entry}" | awk -F: '{print $6}'
}

function configure_local_image_user_sudo() {
  local user_name="${1}"
  local sudoers_path="${TARGET_ROOT}/etc/sudoers.d/10-${user_name}"

  run_logged install -d -m0750 "${TARGET_ROOT}/etc/sudoers.d"
  printf '%s %s\n' "${user_name}" "$(image_user_sudo_policy)" >"${sudoers_path}"
  run_logged chown root:root "${sudoers_path}"
  run_logged chmod 0440 "${sudoers_path}"
}

function lock_local_image_user_password() {
  local user_name="${1}"

  log_command arch-chroot "${TARGET_ROOT}" /usr/bin/passwd -l "${user_name}"
  arch-chroot "${TARGET_ROOT}" /usr/bin/passwd -l "${user_name}" >/dev/null 2>&1 || true
}

function set_local_image_user_password_hash() {
  local user_name="${1}"
  local password_hash="${2}"
  local password_file_chroot="/root/.blackarch-local-user-password"
  local password_file_host="${TARGET_ROOT}${password_file_chroot}"
  local exit_code=0

  run_logged install -m0600 /dev/null "${password_file_host}"
  printf '%s:%s\n' "${user_name}" "${password_hash}" >"${password_file_host}"

  # shellcheck disable=SC2016
  if run_logged arch-chroot "${TARGET_ROOT}" /bin/bash -e -c 'chpasswd -e < "$1"' _ "${password_file_chroot}"; then
    :
  else
    exit_code=$?
    run_logged rm -f "${password_file_host}"
    return "${exit_code}"
  fi

  run_logged rm -f "${password_file_host}"
}

function install_local_image_user_authorized_keys() {
  local user_name="${1}"
  local authorized_keys_file="${2}"
  local user_uid=''
  local user_gid=''
  local user_home=''
  local target_ssh_dir=''
  local target_authorized_keys=''

  user_uid="$(arch-chroot "${TARGET_ROOT}" /usr/bin/id -u "${user_name}")"
  user_gid="$(arch-chroot "${TARGET_ROOT}" /usr/bin/id -g "${user_name}")"
  user_home="$(resolved_target_user_home "${user_name}")"

  if [ -z "${user_home}" ]; then
    printf 'Unable to resolve home directory for local image user: %s\n' "${user_name}" >&2
    return 1
  fi

  target_ssh_dir="${TARGET_ROOT}${user_home}/.ssh"
  target_authorized_keys="${target_ssh_dir}/authorized_keys"
  run_logged install -d -m0700 -o "${user_uid}" -g "${user_gid}" "${target_ssh_dir}"
  run_logged install -m0600 -o "${user_uid}" -g "${user_gid}" "${authorized_keys_file}" "${target_authorized_keys}"
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
