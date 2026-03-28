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

  run_logged install -d -m0755 "${TARGET_ROOT}/etc/ssh/sshd_config.d"
  cat <<'EOF' >"${TARGET_ROOT}/etc/ssh/sshd_config.d/10-blackarch-cloud.conf"
PermitRootLogin no
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

  write_image_fstab
  configure_image_swapfile

  case "${RESOLVED_IMAGE_BOOT_MODE}" in
    bios)
      run_logged arch-chroot "${TARGET_ROOT}" /usr/bin/grub-install --target=i386-pc "${TARGET_LOOP_DEVICE}"
      ;;
    bios+uefi)
      run_logged arch-chroot "${TARGET_ROOT}" /usr/bin/grub-install --target=i386-pc "${TARGET_LOOP_DEVICE}"
      run_logged arch-chroot "${TARGET_ROOT}" /usr/bin/grub-install --target=x86_64-efi --efi-directory=/efi --removable
      ;;
    *)
      printf 'Unsupported boot mode: %s\n' "${RESOLVED_IMAGE_BOOT_MODE}" >&2
      return 1
      ;;
  esac

  run_logged sed -i 's/^GRUB_TIMEOUT=.*$/GRUB_TIMEOUT=1/' "${TARGET_ROOT}/etc/default/grub"
  run_logged sed -i 's/^GRUB_CMDLINE_LINUX=.*$/GRUB_CMDLINE_LINUX="net.ifnames=0"/' "${TARGET_ROOT}/etc/default/grub"
  run_logged sed -i "s/^GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT=\"$(grub_linux_default_cmdline)\"/" "${TARGET_ROOT}/etc/default/grub"
  echo 'GRUB_TERMINAL="serial console"' >>"${TARGET_ROOT}/etc/default/grub"
  echo 'GRUB_SERIAL_COMMAND="serial --speed=115200"' >>"${TARGET_ROOT}/etc/default/grub"
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

function write_image_fstab() {
  run_logged rm -f "${TARGET_ROOT}/etc/fstab"

  case "${RESOLVED_IMAGE_ROOT_FS_TYPE}" in
    btrfs)
      printf 'UUID=%s / btrfs rw,relatime,compress=zstd:1 0 0\n' "${TARGET_ROOT_FS_UUID}" >"${TARGET_ROOT}/etc/fstab"
      ;;
    ext4)
      printf 'UUID=%s / ext4 rw,relatime 0 1\n' "${TARGET_ROOT_FS_UUID}" >"${TARGET_ROOT}/etc/fstab"
      ;;
    *)
      printf 'Unsupported root filesystem type: %s\n' "${RESOLVED_IMAGE_ROOT_FS_TYPE}" >&2
      return 1
      ;;
  esac

  if [ -n "${TARGET_EFI_FS_UUID:-}" ]; then
    printf 'UUID=%s /efi vfat umask=0077 0 2\n' "${TARGET_EFI_FS_UUID}" >>"${TARGET_ROOT}/etc/fstab"
  fi
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

function normalize_grub_root_device() {
  local grub_cfg="${TARGET_ROOT}/boot/grub/grub.cfg"
  local stable_root="UUID=${TARGET_ROOT_FS_UUID}"

  if [ ! -f "${grub_cfg}" ]; then
    printf 'Missing GRUB configuration: %s\n' "${grub_cfg}" >&2
    return 1
  fi

  if grep -F "root=${TARGET_ROOT_PARTITION}" "${grub_cfg}" >/dev/null 2>&1; then
    run_logged sed -i "s#root=${TARGET_ROOT_PARTITION}#root=${stable_root}#g" "${grub_cfg}"
  fi

  if grep -Eq 'root=/dev/loop[0-9]+p[0-9]+' "${grub_cfg}"; then
    printf 'Generated grub.cfg still references a loop device: %s\n' "${grub_cfg}" >&2
    return 1
  fi
}

function generate_final_grub_config() {
  run_logged arch-chroot "${TARGET_ROOT}" /usr/bin/grub-mkconfig -o /boot/grub/grub.cfg
  normalize_grub_root_device
}

function validate_final_boot_artifacts() {
  local grub_cfg="${TARGET_ROOT}/boot/grub/grub.cfg"
  local initramfs_path="${TARGET_ROOT}/boot/initramfs-linux.img"

  if [ ! -f "${initramfs_path}" ]; then
    printf 'Missing initramfs image: %s\n' "${initramfs_path}" >&2
    return 1
  fi

  if [ ! -f "${grub_cfg}" ]; then
    printf 'Missing GRUB configuration: %s\n' "${grub_cfg}" >&2
    return 1
  fi

  if ! grep -Eq '^[[:space:]]*linux[[:space:]]+/boot/vmlinuz-linux([[:space:]]|$)' "${grub_cfg}"; then
    printf 'grub.cfg is missing a linux entry for /boot/vmlinuz-linux: %s\n' "${grub_cfg}" >&2
    return 1
  fi

  if ! grep -Eq '^[[:space:]]*initrd[[:space:]]+/boot/initramfs-linux\.img([[:space:]]|$)' "${grub_cfg}"; then
    printf 'grub.cfg is missing an initrd entry for /boot/initramfs-linux.img: %s\n' "${grub_cfg}" >&2
    return 1
  fi

  if ! grep -Eq 'root=(UUID|PARTUUID)=' "${grub_cfg}"; then
    printf 'grub.cfg is missing a stable root=UUID/PARTUUID kernel argument: %s\n' "${grub_cfg}" >&2
    return 1
  fi

  if grep -Eq 'root=/dev/loop[0-9]+' "${grub_cfg}" || grep -Eq '/dev/loop[0-9]+' "${grub_cfg}"; then
    printf 'grub.cfg still references a loop device path: %s\n' "${grub_cfg}" >&2
    return 1
  fi
}

function finalize_base_image() {
  run_logged rm -rf "${TARGET_ROOT}/etc/pacman.d/gnupg/"
  # Cloud images must skip the autodetect hook here so the initramfs keeps
  # generic storage and filesystem drivers instead of specializing to the
  # build host's loop-backed environment.
  run_logged arch-chroot "${TARGET_ROOT}" /usr/bin/mkinitcpio -p linux -- -S autodetect
  generate_final_grub_config
  validate_final_boot_artifacts
}
