#!/usr/bin/env bash
# shellcheck disable=SC2154

function configure_base_rootfs() {
  run_logged rm -f "${TARGET_ROOT}/etc/machine-id"

  log_command arch-chroot "${TARGET_ROOT}" /usr/bin/systemd-firstboot \
    --locale="${RESOLVED_IMAGE_LOCALE}" \
    --timezone="${RESOLVED_IMAGE_TIMEZONE}" \
    --hostname="${RESOLVED_IMAGE_HOSTNAME}" \
    --keymap="${RESOLVED_IMAGE_KEYMAP}"
  arch-chroot "${TARGET_ROOT}" /usr/bin/systemd-firstboot \
    --locale="${RESOLVED_IMAGE_LOCALE}" \
    --timezone="${RESOLVED_IMAGE_TIMEZONE}" \
    --hostname="${RESOLVED_IMAGE_HOSTNAME}" \
    --keymap="${RESOLVED_IMAGE_KEYMAP}"
  run_logged ln -sf /run/systemd/resolve/stub-resolv.conf "${TARGET_ROOT}/etc/resolv.conf"

  cat <<EOF >"${TARGET_ROOT}/etc/systemd/system/pacman-init.service"
[Unit]
Description=Initializes Pacman keyring
Before=sshd.service cloud-final.service archlinux-keyring-wkd-sync.service
After=time-sync.target
ConditionFirstBoot=yes

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/pacman-key --init
ExecStart=/usr/bin/pacman-key --populate archlinux blackarch

[Install]
WantedBy=multi-user.target
EOF

  cat <<'EOF' >"${TARGET_ROOT}/etc/pacman.d/mirrorlist"
Server = https://fastly.mirror.pkgbuild.com/$repo/os/$arch
Server = https://geo.mirror.pkgbuild.com/$repo/os/$arch
EOF

  log_command arch-chroot "${TARGET_ROOT}" /bin/bash -e
  arch-chroot "${TARGET_ROOT}" /bin/bash -e <<'EOF'
source /etc/profile
systemctl --quiet enable sshd
systemctl --quiet enable systemd-networkd
systemctl --quiet enable systemd-resolved
systemctl --quiet enable systemd-timesyncd
systemctl --quiet enable systemd-time-wait-sync
systemctl --quiet enable pacman-init.service
EOF
}

function configure_base_image() {
  run_logged rm -f "${TARGET_ROOT}/etc/machine-id"

  configure_image_swapfile

  run_logged arch-chroot "${TARGET_ROOT}" /usr/bin/grub-install --target=i386-pc "${TARGET_LOOP_DEVICE}"
  run_logged arch-chroot "${TARGET_ROOT}" /usr/bin/grub-install --target=x86_64-efi --efi-directory=/efi --removable
  run_logged sed -i 's/^GRUB_TIMEOUT=.*$/GRUB_TIMEOUT=1/' "${TARGET_ROOT}/etc/default/grub"
  run_logged sed -i 's/^GRUB_CMDLINE_LINUX=.*$/GRUB_CMDLINE_LINUX="net.ifnames=0"/' "${TARGET_ROOT}/etc/default/grub"
  run_logged sed -i "s/^GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT=\"$(grub_linux_default_cmdline)\"/" "${TARGET_ROOT}/etc/default/grub"
  echo 'GRUB_TERMINAL="serial console"' >>"${TARGET_ROOT}/etc/default/grub"
  echo 'GRUB_SERIAL_COMMAND="serial --speed=115200"' >>"${TARGET_ROOT}/etc/default/grub"
  run_logged arch-chroot "${TARGET_ROOT}" /usr/bin/grub-mkconfig -o /boot/grub/grub.cfg
}

function configure_image_swapfile() {
  case "${RESOLVED_IMAGE_ROOT_FS_TYPE}" in
    btrfs)
      run_logged arch-chroot "${TARGET_ROOT}" /usr/bin/btrfs subvolume create /swap
      run_logged chattr +C "${TARGET_ROOT}/swap"
      run_logged chmod 0700 "${TARGET_ROOT}/swap"
      run_logged arch-chroot "${TARGET_ROOT}" /usr/bin/btrfs filesystem mkswapfile --size "${RESOLVED_IMAGE_SWAP_SIZE}" --uuid clear /swap/swapfile
      echo "/swap/swapfile none swap defaults 0 0" >>"${TARGET_ROOT}/etc/fstab"
      ;;
    ext4)
      # shellcheck disable=SC2016
      log_command arch-chroot "${TARGET_ROOT}" /bin/bash -e -c 'fallocate -l "$1" /swapfile && chmod 0600 /swapfile && mkswap /swapfile' _ "${RESOLVED_IMAGE_SWAP_SIZE}"
      # shellcheck disable=SC2016
      arch-chroot "${TARGET_ROOT}" /bin/bash -e -c \
        'fallocate -l "$1" /swapfile && chmod 0600 /swapfile && mkswap /swapfile' \
        _ "${RESOLVED_IMAGE_SWAP_SIZE}"
      echo "/swapfile none swap defaults 0 0" >>"${TARGET_ROOT}/etc/fstab"
      ;;
    *)
      printf 'Unsupported root filesystem type: %s\n' "${RESOLVED_IMAGE_ROOT_FS_TYPE}" >&2
      return 1
      ;;
  esac
}

function grub_linux_default_cmdline() {
  case "${RESOLVED_IMAGE_ROOT_FS_TYPE}" in
    btrfs)
      printf '%s\n' 'rootflags=compress=zstd:1 console=tty0 console=ttyS0,115200'
      ;;
    ext4)
      printf '%s\n' 'console=tty0 console=ttyS0,115200'
      ;;
    *)
      printf 'Unsupported root filesystem type: %s\n' "${RESOLVED_IMAGE_ROOT_FS_TYPE}" >&2
      return 1
      ;;
  esac
}

function finalize_base_image() {
  run_logged rm -rf "${TARGET_ROOT}/etc/pacman.d/gnupg/"
  run_logged arch-chroot "${TARGET_ROOT}" /usr/bin/mkinitcpio -p linux -- -S autodetect
}
