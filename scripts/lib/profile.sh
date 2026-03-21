#!/usr/bin/env bash

function apply_profile_image_customization() {
  case "${RESOLVED_IMAGE_ENABLE_QEMU_GUEST_AGENT}" in
    true)
      arch-chroot "${TARGET_ROOT}" /usr/bin/pacman -S --noconfirm --needed --noprogressbar --color never qemu-guest-agent
      arch-chroot "${TARGET_ROOT}" /usr/bin/systemctl enable qemu-guest-agent
      ;;
    false)
      arch-chroot "${TARGET_ROOT}" /usr/bin/systemctl disable qemu-guest-agent >/dev/null 2>&1 || true
      ;;
  esac
}
