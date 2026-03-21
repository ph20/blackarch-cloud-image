#!/usr/bin/env bash

set -o nounset
set -o errexit
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
# shellcheck disable=SC2016
readonly ARCH_MIRROR='https://fastly.mirror.pkgbuild.com/$repo/os/$arch'
readonly PACSTRAP_GPGDIR="/etc/pacman.d/gnupg"

# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=scripts/lib/config.sh
source "${SCRIPT_DIR}/lib/config.sh"
# shellcheck source=scripts/lib/logging.sh
source "${SCRIPT_DIR}/lib/logging.sh"
# shellcheck source=scripts/lib/manifest.sh
source "${SCRIPT_DIR}/lib/manifest.sh"
# shellcheck source=scripts/lib/mounts.sh
source "${SCRIPT_DIR}/lib/mounts.sh"

function cleanup() {
  cleanup_stage_pacman_config || true

  if [ -n "${TARGET_ROOT:-}" ] && [ -d "${TARGET_ROOT:-}" ]; then
    unmount_mount_tree "${TARGET_ROOT}" || true
  fi

  if [ -n "${ROOTFS_STAGE_DIR:-}" ] && [ -d "${ROOTFS_STAGE_DIR:-}" ]; then
    rm -rf "${ROOTFS_STAGE_DIR}"
  fi
}
trap cleanup EXIT

function bootstrap_rootfs() {
  local pacman_dbpath="${ROOTFS_STAGE_DIR}/pacman-db"
  local pacman_cachedir="${ROOTFS_STAGE_DIR}/pacman-cache"
  local -a bootstrap_packages=(
    base
    linux
    grub
    openssh
    sudo
    btrfs-progs
    dosfstools
    dhclient
    efibootmgr
    curl
    ca-certificates
    gnupg
    mkinitcpio
    iptables-nft
    cloud-init
    cloud-guest-utils
    gptfdisk
  )

  mkdir -p "${pacman_dbpath}" "${pacman_cachedir}"

  cat <<EOF >"${ROOTFS_STAGE_DIR}/pacman.conf"
[options]
Architecture = auto
SigLevel = DatabaseOptional
DBPath = ${pacman_dbpath}
CacheDir = ${pacman_cachedir}
GPGDir = ${PACSTRAP_GPGDIR}

[core]
Include = ${ROOTFS_STAGE_DIR}/mirrorlist

[extra]
Include = ${ROOTFS_STAGE_DIR}/mirrorlist
EOF

  printf 'Server = %s\n' "${ARCH_MIRROR}" >"${ROOTFS_STAGE_DIR}/mirrorlist"

  pacstrap -C "${ROOTFS_STAGE_DIR}/pacman.conf" -M "${TARGET_ROOT}" "${bootstrap_packages[@]}"
  gpgconf --homedir "${TARGET_ROOT}/etc/pacman.d/gnupg" --kill gpg-agent || true
  install -Dm0644 "${ROOTFS_STAGE_DIR}/mirrorlist" "${TARGET_ROOT}/etc/pacman.d/mirrorlist"
}

function prepare_stage_pacman_config() {
  TARGET_PACMAN_CONFIG="/root/pacman-stage-build.conf"
  export TARGET_PACMAN_CONFIG

  install -Dm0644 "${TARGET_ROOT}/etc/pacman.conf" "${TARGET_ROOT}${TARGET_PACMAN_CONFIG}"
  sed -i '/^[[:space:]]*CheckSpace[[:space:]]*$/d' "${TARGET_ROOT}${TARGET_PACMAN_CONFIG}"
}

function cleanup_stage_pacman_config() {
  if [ -n "${TARGET_PACMAN_CONFIG:-}" ]; then
    rm -f "${TARGET_ROOT}${TARGET_PACMAN_CONFIG}"
    unset TARGET_PACMAN_CONFIG
  fi
}

function pack_rootfs_artifact() {
  local tmp_artifact="${ROOTFS_ARTIFACT_PATH}.tmp.$$"

  rm -f "${ROOTFS_ARTIFACT_PATH}" "${ROOTFS_MANIFEST_PATH}" "${tmp_artifact}"
  unmount_mount_tree "${TARGET_ROOT}"
  tar --zstd --acls --xattrs --numeric-owner -C "${TARGET_ROOT}" -cpf "${tmp_artifact}" .
  mv "${tmp_artifact}" "${ROOTFS_ARTIFACT_PATH}"
  chown_to_invoking_user "${ROOTFS_ARTIFACT_PATH}" 2>/dev/null || true
}

function main() {
  require_root
  resolve_build_context "${1:-${BUILD_VERSION:-}}"
  ensure_directories "${ROOTFS_OUTPUT_DIR}" "${TMP_ROOT}"

  ROOTFS_STAGE_DIR="$(prepare_stage_workdir rootfs)"
  readonly ROOTFS_STAGE_DIR
  TARGET_ROOT="${ROOTFS_STAGE_DIR}/tree"
  readonly TARGET_ROOT
  mkdir -p "${TARGET_ROOT}"

  # shellcheck source=images/base.sh
  source "${PROJECT_ROOT}/images/base.sh"
  # shellcheck source=images/blackarch-cloud.sh
  source "${PROJECT_ROOT}/images/blackarch-cloud.sh"

  log_step "Stage 1: bootstrapping common Arch rootfs"
  bootstrap_rootfs

  log_step "Stage 1: applying common base customization"
  configure_base_rootfs

  log_step "Stage 1: preparing package manager for rootfs-only customization"
  prepare_stage_pacman_config

  log_step "Stage 1: configuring BlackArch and cloud-init"
  configure_blackarch_rootfs
  cleanup_stage_pacman_config

  log_step "Stage 1: packing reusable rootfs artifact"
  pack_rootfs_artifact

  log_step "Stage 1: writing rootfs manifest"
  write_rootfs_manifest
  chown_to_invoking_user "${ROOTFS_MANIFEST_PATH}" 2>/dev/null || true
}

main "${1:-}"
