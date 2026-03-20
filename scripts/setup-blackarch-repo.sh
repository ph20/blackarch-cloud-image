#!/usr/bin/env bash

set -o nounset
set -o errexit
set -o pipefail

# Matches the keyring bundle version used by the official strap.sh snapshot.
readonly DEFAULT_BLACKARCH_KEYRING_VERSION="20251011"
readonly LEGACY_STRAP_URL="${BLACKARCH_STRAP_URL:-https://blackarch.org/strap.sh}"
readonly KEYRING_VERSION="${BLACKARCH_KEYRING_VERSION:-${DEFAULT_BLACKARCH_KEYRING_VERSION}}"
readonly KEYRING_ARCHIVE="blackarch-keyring-${KEYRING_VERSION}.tar.gz"
readonly KEYRING_URL="https://www.blackarch.org/keyring/${KEYRING_ARCHIVE}"
readonly MIRRORLIST_URL="https://blackarch.org/blackarch-mirrorlist"
readonly MIRRORLIST_PATH="/etc/pacman.d/blackarch-mirrorlist"
readonly PACMAN_CONF="/etc/pacman.conf"
readonly PACMAN_KEYRING_DIR="/usr/share/pacman/keyrings"
WORKDIR="$(mktemp -d)"
readonly WORKDIR

function cleanup() {
  rm -rf "${WORKDIR}"
}
trap cleanup EXIT

function run_legacy_strap() {
  local strap_path="${WORKDIR}/strap.sh"

  curl -fsSL "${LEGACY_STRAP_URL}" -o "${strap_path}"

  if [ -n "${BLACKARCH_STRAP_SHA256:-}" ]; then
    echo "${BLACKARCH_STRAP_SHA256}  ${strap_path}" | sha256sum --check --status -
  fi

  bash "${strap_path}"
}

function require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "root is required" >&2
    exit 1
  fi
}

function install_keyring() {
  local extracted_dir="${WORKDIR}/blackarch-keyring-${KEYRING_VERSION}"

  curl -fsSL "${KEYRING_URL}" -o "${WORKDIR}/${KEYRING_ARCHIVE}"
  tar xzf "${WORKDIR}/${KEYRING_ARCHIVE}" -C "${WORKDIR}"

  install -Dm0644 \
    "${extracted_dir}/blackarch.gpg" \
    "${PACMAN_KEYRING_DIR}/blackarch.gpg"
  install -Dm0644 \
    "${extracted_dir}/blackarch-trusted" \
    "${PACMAN_KEYRING_DIR}/blackarch-trusted"
  install -Dm0644 \
    "${extracted_dir}/blackarch-revoked" \
    "${PACMAN_KEYRING_DIR}/blackarch-revoked"

  if [ ! -d /etc/pacman.d/gnupg ] || [ -z "$(find /etc/pacman.d/gnupg -mindepth 1 -maxdepth 1 2>/dev/null)" ]; then
    pacman-key --init
    pacman-key --populate archlinux
  fi

  pacman-key --populate blackarch
}

function install_mirrorlist() {
  curl -fsSL "${MIRRORLIST_URL}" -o "${MIRRORLIST_PATH}"
}

function ensure_blackarch_repo() {
  if grep -q '^\[blackarch\]$' "${PACMAN_CONF}"; then
    return
  fi

  cat >> "${PACMAN_CONF}" <<'EOF'
[blackarch]
Include = /etc/pacman.d/blackarch-mirrorlist
EOF
}

function sync_blackarch_repo() {
  pacman -Syy
  pacman -S --noconfirm --needed blackarch-mirrorlist

  if [ -f /etc/pacman.d/blackarch-mirrorlist.pacnew ]; then
    mv /etc/pacman.d/blackarch-mirrorlist.pacnew /etc/pacman.d/blackarch-mirrorlist
  fi
}

function main() {
  require_root

  if [ -n "${BLACKARCH_STRAP_URL:-}" ] || [ -n "${BLACKARCH_STRAP_SHA256:-}" ]; then
    run_legacy_strap
    return
  fi

  install_keyring
  install_mirrorlist
  ensure_blackarch_repo
  sync_blackarch_repo
}

main
