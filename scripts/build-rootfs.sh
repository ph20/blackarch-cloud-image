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
  local pacman_hookdir="${ROOTFS_STAGE_DIR}/pacman-hooks"
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

  run_logged mkdir -p "${pacman_dbpath}" "${pacman_cachedir}" "${pacman_hookdir}"
  run_logged ln -sf /dev/null "${pacman_hookdir}/90-mkinitcpio-install.hook"

  cat <<EOF >"${ROOTFS_STAGE_DIR}/pacman.conf"
[options]
Architecture = auto
SigLevel = DatabaseOptional
DBPath = ${pacman_dbpath}
CacheDir = ${pacman_cachedir}
GPGDir = ${PACSTRAP_GPGDIR}
HookDir = ${pacman_hookdir}

[core]
Include = ${ROOTFS_STAGE_DIR}/mirrorlist

[extra]
Include = ${ROOTFS_STAGE_DIR}/mirrorlist
EOF

  printf 'Server = %s\n' "${ARCH_MIRROR}" >"${ROOTFS_STAGE_DIR}/mirrorlist"

  run_logged pacstrap -C "${ROOTFS_STAGE_DIR}/pacman.conf" -M "${TARGET_ROOT}" "${bootstrap_packages[@]}"
  run_logged gpgconf --homedir "${TARGET_ROOT}/etc/pacman.d/gnupg" --kill all || true
  run_logged install -Dm0644 "${ROOTFS_STAGE_DIR}/mirrorlist" "${TARGET_ROOT}/etc/pacman.d/mirrorlist"
}

function prepare_staged_kernel_artifacts() {
  local modules_dir=''
  local pkgbase=''
  local kernelbase=''
  local kernel_image=''
  local kernel_copy_path=''
  local preset_path=''
  local preset_template=''
  local preset_tmp_path=''
  local prepared_count=0

  preset_template="${TARGET_ROOT}/usr/share/mkinitcpio/hook.preset"

  shopt -s nullglob
  for modules_dir in "${TARGET_ROOT}"/usr/lib/modules/*; do
    if [ ! -d "${modules_dir}" ] || [ ! -r "${modules_dir}/pkgbase" ]; then
      continue
    fi

    read -r pkgbase < "${modules_dir}/pkgbase"

    if [ -z "${pkgbase}" ]; then
      continue
    fi

    if [ -r "${modules_dir}/kernelbase" ]; then
      read -r kernelbase < "${modules_dir}/kernelbase"
    else
      kernelbase="${pkgbase}"
    fi

    kernel_image="${modules_dir}/vmlinuz"
    kernel_copy_path="${TARGET_ROOT}/boot/vmlinuz-${pkgbase}"
    preset_path="${TARGET_ROOT}/etc/mkinitcpio.d/${pkgbase}.preset"
    preset_tmp_path="${ROOTFS_STAGE_DIR}/${pkgbase}.preset.tmp"

    if [ -r "${kernel_image}" ]; then
      run_logged install -Dm0644 "${kernel_image}" "${kernel_copy_path}"
    fi

    if [ -r "${preset_template}" ]; then
      log_command sed \
        -e "s|%PKGBASE%|${pkgbase}|g" \
        -e "s|%KERNELBASE%|${kernelbase}|g" \
        "${preset_template}"
      sed \
        -e "s|%PKGBASE%|${pkgbase}|g" \
        -e "s|%KERNELBASE%|${kernelbase}|g" \
        "${preset_template}" > "${preset_tmp_path}"

      if grep -Eq '%[A-Z_][A-Z0-9_]*%' "${preset_tmp_path}"; then
        printf 'Generated preset still contains unresolved template token(s): %s\n' "${preset_tmp_path}" >&2
        sed -n '1,80p' "${preset_tmp_path}" >&2
        return 1
      fi

      run_logged install -Dm0644 "${preset_tmp_path}" "${preset_path}"
      run_logged rm -f "${preset_tmp_path}"
    fi

    prepared_count=$((prepared_count + 1))
  done
  shopt -u nullglob

  if [ "${prepared_count}" -eq 0 ]; then
    printf 'No installed kernel artifacts were discovered under %s/usr/lib/modules\n' "${TARGET_ROOT}" >&2
    return 1
  fi
}

function prepare_stage_pacman_config() {
  TARGET_PACMAN_CONFIG="/root/pacman-stage-build.conf"
  export TARGET_PACMAN_CONFIG

  run_logged install -Dm0644 "${TARGET_ROOT}/etc/pacman.conf" "${TARGET_ROOT}${TARGET_PACMAN_CONFIG}"
  run_logged sed -i '/^[[:space:]]*CheckSpace[[:space:]]*$/d' "${TARGET_ROOT}${TARGET_PACMAN_CONFIG}"
}

function cleanup_stage_pacman_config() {
  if [ -n "${TARGET_PACMAN_CONFIG:-}" ]; then
    run_logged rm -f "${TARGET_ROOT}${TARGET_PACMAN_CONFIG}"
    unset TARGET_PACMAN_CONFIG
  fi
}

function pack_rootfs_artifact() {
  local tmp_artifact="${ROOTFS_ARTIFACT_PATH}.tmp.$$"

  run_logged rm -f "${ROOTFS_ARTIFACT_PATH}" "${ROOTFS_MANIFEST_PATH}" "${tmp_artifact}"
  unmount_mount_tree "${TARGET_ROOT}"
  run_logged gpgconf --homedir "${TARGET_ROOT}/etc/pacman.d/gnupg" --kill all || true
  run_logged tar --zstd --acls --xattrs --numeric-owner -C "${TARGET_ROOT}" -cpf "${tmp_artifact}" .
  run_logged mv "${tmp_artifact}" "${ROOTFS_ARTIFACT_PATH}"
  chown_to_invoking_user "${ROOTFS_ARTIFACT_PATH}" 2>/dev/null || true
}

function main() {
  require_root
  resolve_build_context "${1:-}"
  ensure_directories "${ROOTFS_OUTPUT_DIR}" "${TMP_ROOT}"

  ROOTFS_STAGE_DIR="$(prepare_stage_workdir rootfs)"
  readonly ROOTFS_STAGE_DIR
  TARGET_ROOT="${ROOTFS_STAGE_DIR}/tree"
  readonly TARGET_ROOT
  run_logged mkdir -p "${TARGET_ROOT}"

  # shellcheck source=images/base.sh
  source "${PROJECT_ROOT}/images/base.sh"
  # shellcheck source=images/blackarch-cloud.sh
  source "${PROJECT_ROOT}/images/blackarch-cloud.sh"

  log_step "Stage 1: bootstrapping common Arch rootfs"
  bootstrap_rootfs

  log_step "Stage 1: preparing kernel preset and boot artifacts"
  prepare_staged_kernel_artifacts

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
