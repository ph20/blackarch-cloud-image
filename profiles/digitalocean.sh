#!/usr/bin/env bash
# shellcheck disable=SC2154

function profile_hook() {
  local hook_name="${1}"

  case "${hook_name}" in
    finalize)
      run_logged arch-chroot "${TARGET_ROOT}" /usr/bin/cloud-init clean
      run_logged rm -rf "${TARGET_ROOT}/var/lib/cloud/"
      ;;
  esac
}
