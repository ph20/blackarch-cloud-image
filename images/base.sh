#!/usr/bin/env bash
# shellcheck disable=SC2154

function configure_base_rootfs() {
  rm -f "${TARGET_ROOT}/etc/machine-id"

  arch-chroot "${TARGET_ROOT}" /usr/bin/systemd-firstboot \
    --locale="${RESOLVED_IMAGE_LOCALE}" \
    --timezone="${RESOLVED_IMAGE_TIMEZONE}" \
    --hostname="${RESOLVED_IMAGE_HOSTNAME}" \
    --keymap="${RESOLVED_IMAGE_KEYMAP}"
  ln -sf /run/systemd/resolve/stub-resolv.conf "${TARGET_ROOT}/etc/resolv.conf"

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

  arch-chroot "${TARGET_ROOT}" /bin/bash -e <<'EOF'
source /etc/profile
systemctl enable sshd
systemctl enable systemd-networkd
systemctl enable systemd-resolved
systemctl enable systemd-timesyncd
systemctl enable systemd-time-wait-sync
systemctl enable pacman-init.service
EOF
}

function configure_base_image() {
  rm -f "${TARGET_ROOT}/etc/machine-id"

  arch-chroot "${TARGET_ROOT}" /usr/bin/btrfs subvolume create /swap
  chattr +C "${TARGET_ROOT}/swap"
  chmod 0700 "${TARGET_ROOT}/swap"
  arch-chroot "${TARGET_ROOT}" /usr/bin/btrfs filesystem mkswapfile --size "${RESOLVED_IMAGE_SWAP_SIZE}" --uuid clear /swap/swapfile
  echo "/swap/swapfile none swap defaults 0 0" >>"${TARGET_ROOT}/etc/fstab"

  arch-chroot "${TARGET_ROOT}" /usr/bin/grub-install --target=i386-pc "${TARGET_LOOP_DEVICE}"
  arch-chroot "${TARGET_ROOT}" /usr/bin/grub-install --target=x86_64-efi --efi-directory=/efi --removable
  sed -i 's/^GRUB_TIMEOUT=.*$/GRUB_TIMEOUT=1/' "${TARGET_ROOT}/etc/default/grub"
  sed -i 's/^GRUB_CMDLINE_LINUX=.*$/GRUB_CMDLINE_LINUX="net.ifnames=0"/' "${TARGET_ROOT}/etc/default/grub"
  sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT="rootflags=compress=zstd:1 console=tty0 console=ttyS0,115200"/' "${TARGET_ROOT}/etc/default/grub"
  echo 'GRUB_TERMINAL="serial console"' >>"${TARGET_ROOT}/etc/default/grub"
  echo 'GRUB_SERIAL_COMMAND="serial --speed=115200"' >>"${TARGET_ROOT}/etc/default/grub"
  arch-chroot "${TARGET_ROOT}" /usr/bin/grub-mkconfig -o /boot/grub/grub.cfg
}

function finalize_base_image() {
  rm -rf "${TARGET_ROOT}/etc/pacman.d/gnupg/"
  arch-chroot "${TARGET_ROOT}" /usr/bin/mkinitcpio -p linux -- -S autodetect
}
