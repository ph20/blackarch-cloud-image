#!/usr/bin/env bash
# shellcheck disable=SC2154

function chroot_pacman_sync() {
  local -a pacman_command=(/usr/bin/pacman -S --noconfirm --needed --noprogressbar --color never)

  if [ -n "${TARGET_PACMAN_CONFIG:-}" ]; then
    pacman_command+=(--config "${TARGET_PACMAN_CONFIG}")
  fi

  arch-chroot "${TARGET_ROOT}" "${pacman_command[@]}" "${@}"
}

function install_blackarch_profile() {
  local -a common_packages=(
    mlocate
    net-tools
    strace
    vim
    rsync
    sqlmap
    nikto
    nmap
    hydra
    medusa
    metasploit
    hping
    wpscan
    joomscan
    masscan
    zaproxy
    libxtst
    xorg-xauth
    burpsuite
  )

  case "${RESOLVED_BLACKARCH_PROFILE}" in
    core)
      ;;
    common)
      chroot_pacman_sync "${common_packages[@]}"
      ;;
    *)
      printf 'Unsupported BLACKARCH_PROFILE: %s\n' "${RESOLVED_BLACKARCH_PROFILE}" >&2
      return 1
      ;;
  esac
}

function default_user_sudo_policy() {
  case "${RESOLVED_IMAGE_PASSWORDLESS_SUDO}" in
    true)
      printf '%s\n' 'ALL=(ALL) NOPASSWD:ALL'
      ;;
    false)
      printf '%s\n' 'ALL=(ALL) ALL'
      ;;
  esac
}

function configure_blackarch_rootfs() {
  local -a extra_blackarch_packages=()
  local -a cloud_init_services=(
    cloud-init-main.service
    cloud-init-local.service
    cloud-init-network.service
    cloud-config.service
    cloud-final.service
  )
  local -a setup_env=(/usr/bin/env)
  local default_user_sudo=''

  install -Dm0755 \
    "${PROJECT_ROOT}/scripts/setup-blackarch-repo.sh" \
    "${TARGET_ROOT}/root/setup-blackarch-repo.sh"

  if [ -n "${BLACKARCH_KEYRING_VERSION:-}" ]; then
    setup_env+=("BLACKARCH_KEYRING_VERSION=${BLACKARCH_KEYRING_VERSION}")
  fi

  if [ -n "${BLACKARCH_KEYRING_SHA256:-}" ]; then
    setup_env+=("BLACKARCH_KEYRING_SHA256=${BLACKARCH_KEYRING_SHA256}")
  fi

  if [ -n "${BLACKARCH_STRAP_URL:-}" ]; then
    setup_env+=("BLACKARCH_STRAP_URL=${BLACKARCH_STRAP_URL}")
  fi

  if [ -n "${BLACKARCH_STRAP_SHA256:-}" ]; then
    setup_env+=("BLACKARCH_STRAP_SHA256=${BLACKARCH_STRAP_SHA256}")
  fi

  if [ -n "${TARGET_PACMAN_CONFIG:-}" ]; then
    setup_env+=("BLACKARCH_PACMAN_CONFIG=${TARGET_PACMAN_CONFIG}")
  fi

  setup_env+=(/root/setup-blackarch-repo.sh)
  arch-chroot "${TARGET_ROOT}" "${setup_env[@]}"
  rm -f "${TARGET_ROOT}/root/setup-blackarch-repo.sh"

  install_blackarch_profile

  if [ -n "${BLACKARCH_PACKAGES:-}" ]; then
    read -r -a extra_blackarch_packages <<<"${BLACKARCH_PACKAGES}"
    chroot_pacman_sync "${extra_blackarch_packages[@]}"
  fi

  default_user_sudo="$(default_user_sudo_policy)"

  cat <<EOF >"${TARGET_ROOT}/etc/cloud/cloud.cfg.d/10_blackarch.cfg"
users:
  - default
disable_root: true
ssh_pwauth: false
system_info:
  distro: arch
  default_user:
    name: ${RESOLVED_IMAGE_DEFAULT_USER}
    gecos: ${RESOLVED_IMAGE_DEFAULT_USER_GECOS}
    groups: [wheel, systemd-journal]
    sudo: ["${default_user_sudo}"]
    lock_passwd: true
    shell: /bin/bash
EOF

  arch-chroot "${TARGET_ROOT}" /usr/bin/passwd -l root || true
  arch-chroot "${TARGET_ROOT}" /usr/bin/systemctl enable "${cloud_init_services[@]}"
}
