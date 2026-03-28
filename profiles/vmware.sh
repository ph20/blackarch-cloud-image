#!/usr/bin/env bash
# shellcheck disable=SC2154

function profile_hook() {
  local hook_name="${1}"
  local local_user=''

  case "${hook_name}" in
    finalize)
      local_user="${RESOLVED_PROFILE_VMWARE_LOCAL_USER}"
      ensure_local_image_user "${local_user}" "BlackArch VMware User" "wheel,systemd-journal"
      configure_local_image_user_sudo "${local_user}"

      if [ -n "${RESOLVED_PROFILE_VMWARE_LOCAL_PASSWORD_HASH:-}" ]; then
        set_local_image_user_password_hash "${local_user}" "${RESOLVED_PROFILE_VMWARE_LOCAL_PASSWORD_HASH}"
      else
        lock_local_image_user_password "${local_user}"
      fi

      if [ -n "${RESOLVED_PROFILE_VMWARE_AUTHORIZED_KEYS_FILE:-}" ]; then
        install_local_image_user_authorized_keys "${local_user}" "${RESOLVED_PROFILE_VMWARE_AUTHORIZED_KEYS_FILE}"
      fi
      ;;
  esac
}
