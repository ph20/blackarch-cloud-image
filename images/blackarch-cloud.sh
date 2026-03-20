#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2154

IMAGE_NAME="BlackArch-Linux-x86_64-cloudimg-${build_version}.qcow2"
DISK_SIZE="${DISK_SIZE:-}"
PACKAGES=(cloud-init cloud-guest-utils gptfdisk)
SERVICES=(cloud-init-main.service cloud-init-local.service cloud-init-network.service cloud-config.service cloud-final.service)

function pre() {
  local -a extra_blackarch_packages=()
  local -a strap_env=(/usr/bin/env)

  install -Dm0755 \
    "${PROJECT_ROOT}/scripts/setup-blackarch-repo.sh" \
    "${MOUNT}/root/setup-blackarch-repo.sh"

  if [ -n "${BLACKARCH_STRAP_URL:-}" ]; then
    strap_env+=("BLACKARCH_STRAP_URL=${BLACKARCH_STRAP_URL}")
  fi

  if [ -n "${BLACKARCH_STRAP_SHA256:-}" ]; then
    strap_env+=("BLACKARCH_STRAP_SHA256=${BLACKARCH_STRAP_SHA256}")
  fi

  strap_env+=(/root/setup-blackarch-repo.sh)
  arch-chroot "${MOUNT}" "${strap_env[@]}"
  rm -f "${MOUNT}/root/setup-blackarch-repo.sh"

  if [ -n "${BLACKARCH_PACKAGES:-}" ]; then
    # shellcheck disable=SC2206
    extra_blackarch_packages=(${BLACKARCH_PACKAGES})
    arch-chroot "${MOUNT}" /usr/bin/pacman -S --noconfirm --needed "${extra_blackarch_packages[@]}"
  fi

  cat <<'EOF' >"${MOUNT}/etc/cloud/cloud.cfg.d/10_blackarch.cfg"
users:
  - default
disable_root: true
ssh_pwauth: false
system_info:
  distro: arch
  default_user:
    name: arch
    gecos: BlackArch Cloud User
    groups: [wheel, systemd-journal]
    sudo: ["ALL=(ALL) NOPASSWD:ALL"]
    lock_passwd: true
    shell: /bin/bash
EOF

  arch-chroot "${MOUNT}" /usr/bin/passwd -l root || true

  sed -Ei 's/^(GRUB_CMDLINE_LINUX_DEFAULT=.*)"$/\1 console=tty0 console=ttyS0,115200"/' "${MOUNT}/etc/default/grub"
  echo 'GRUB_TERMINAL="serial console"' >>"${MOUNT}/etc/default/grub"
  echo 'GRUB_SERIAL_COMMAND="serial --speed=115200"' >>"${MOUNT}/etc/default/grub"
  arch-chroot "${MOUNT}" /usr/bin/grub-mkconfig -o /boot/grub/grub.cfg
}

function post() {
  qemu-img convert -c -f raw -O qcow2 "${1}" "${2}"
  rm -f "${1}"
}
