#!/usr/bin/env bash

function apply_profile_image_customization() {
  case "${RESOLVED_IMAGE_ENABLE_QEMU_GUEST_AGENT}" in
    true)
      run_logged arch-chroot "${TARGET_ROOT}" /usr/bin/pacman -S --noconfirm --needed --noprogressbar --color never qemu-guest-agent
      run_logged arch-chroot "${TARGET_ROOT}" /usr/bin/systemctl --quiet enable qemu-guest-agent
      ;;
    false)
      log_command arch-chroot "${TARGET_ROOT}" /usr/bin/systemctl --quiet disable qemu-guest-agent
      arch-chroot "${TARGET_ROOT}" /usr/bin/systemctl --quiet disable qemu-guest-agent >/dev/null 2>&1 || true
      ;;
  esac
}
