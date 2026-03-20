#!/usr/bin/env bash

set -o nounset
set -o errexit
set -o pipefail
set -o errtrace

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_ROOT
readonly DEFAULT_DISK_SIZE="${DEFAULT_DISK_SIZE:-2G}"
readonly IMAGE="image.img"
# shellcheck disable=SC2016
readonly MIRROR='https://fastly.mirror.pkgbuild.com/$repo/os/$arch'
readonly IMAGE_NAME_PREFIX="BlackArch-Linux-x86_64-cloudimg"
readonly OUTPUT="${PROJECT_ROOT}/output"
readonly TMP_ROOT="${PROJECT_ROOT}/tmp"
readonly PACSTRAP_GPGDIR="/etc/pacman.d/gnupg"

function status_line() {
  if [ -n "${STATUS_FD_READY:-}" ]; then
    printf '%s\n' "${1}" >&3
  fi
  printf '%s\n' "${1}"
}

function log_step() {
  CURRENT_STEP="${1}"
  status_line "==> ${1}"
}

function handle_error() {
  local exit_code=$?

  if [ -n "${BUILD_LOG:-}" ]; then
    status_line "Build failed during step: ${CURRENT_STEP:-unknown}"
    status_line "See build log: ${BUILD_LOG}"
  fi

  exit "${exit_code}"
}

function handle_signal() {
  local signal_name="${1}"
  local exit_code="${2}"

  trap - ERR INT TERM

  status_line "Build interrupted by ${signal_name} during step: ${CURRENT_STEP:-unknown}"
  status_line "Cleaning up temporary runtime artifacts..."

  if [ -n "${BUILD_LOG:-}" ]; then
    status_line "See build log: ${BUILD_LOG}"
  fi

  exit "${exit_code}"
}

function resolve_build_version() {
  if [ -z "${1:-}" ]; then
    build_version="$(date +%Y%m%d).0"
    build_version_was_defaulted=1
  else
    build_version="${1}"
    build_version_was_defaulted=0
  fi

  readonly build_version
  readonly build_version_was_defaulted
}

function setup_logging() {
  mkdir -p "${OUTPUT}" "${TMP_ROOT}"

  BUILD_LOG="${OUTPUT}/${IMAGE_NAME_PREFIX}-${build_version}.build.log"
  readonly BUILD_LOG
  : > "${BUILD_LOG}"

  if [ -n "${SUDO_UID:-}" ] && [ -n "${SUDO_GID:-}" ]; then
    chown "${SUDO_UID}:${SUDO_GID}" "${OUTPUT}" "${BUILD_LOG}"
  fi

  exec 3>&1
  STATUS_FD_READY=1
  exec >>"${BUILD_LOG}" 2>&1

  log_step "Writing build log to ${BUILD_LOG}"

  if [ "${build_version_was_defaulted}" -eq 1 ]; then
    status_line "WARNING: BUILD_VERSION wasn't set!"
    status_line "Falling back to ${build_version}"
  fi
}
trap handle_error ERR
trap 'handle_signal SIGINT 130' INT
trap 'handle_signal SIGTERM 143' TERM

function init() {
  local tmpdir

  mkdir -p "${OUTPUT}" "${TMP_ROOT}"
  tmpdir="$(mktemp -d --tmpdir="${TMP_ROOT}" build.XXXXXXXXXX)"
  readonly TMPDIR="${tmpdir}"

  if [ -n "${SUDO_UID:-}" ] && [ -n "${SUDO_GID:-}" ]; then
    chown "${SUDO_UID}:${SUDO_GID}" "${OUTPUT}" "${TMPDIR}"
  fi

  cd "${TMPDIR}"
  readonly MOUNT="${PWD}/mount"
  mkdir "${MOUNT}"
}

function cleanup() {
  set +o errexit

  if [ -n "${MOUNT:-}" ] && mountpoint -q "${MOUNT}"; then
    umount --recursive "${MOUNT}" || true
  fi

  if [ -n "${LOOPDEV:-}" ]; then
    losetup -d "${LOOPDEV}" || true
  fi

  if [ -n "${TMPDIR:-}" ] && [ -d "${TMPDIR}" ]; then
    rm -rf "${TMPDIR}"
  fi
}
trap cleanup EXIT

function wait_until_settled() {
  udevadm settle
  blockdev --flushbufs --rereadpt "${1}"
  until test -e "${1}p3"; do
    echo "${1}p3 doesn't exist yet..."
    sleep 1
  done
}

function setup_disk() {
  truncate -s "${DEFAULT_DISK_SIZE}" "${IMAGE}"
  sgdisk --align-end \
    --clear \
    --new 0:0:+1M --typecode=0:ef02 --change-name=0:'BIOS boot partition' \
    --new 0:0:+300M --typecode=0:ef00 --change-name=0:'EFI system partition' \
    --new 0:0:0 --typecode=0:8304 --change-name=0:'Arch Linux root' \
    "${IMAGE}"

  LOOPDEV="$(losetup --find --partscan --show "${IMAGE}")"
  wait_until_settled "${LOOPDEV}"

  mkfs.fat -F 32 -S 4096 "${LOOPDEV}p2"
  mkfs.btrfs "${LOOPDEV}p3"

  mount -o compress=zstd:1 "${LOOPDEV}p3" "${MOUNT}"
  mount --mkdir "${LOOPDEV}p2" "${MOUNT}/efi"
}

function bootstrap() {
  local pacman_dbpath="${TMPDIR}/pacman-db"
  local pacman_cachedir="${TMPDIR}/pacman-cache"

  mkdir -p "${pacman_dbpath}" "${pacman_cachedir}"

  cat <<EOF >pacman.conf
[options]
Architecture = auto
SigLevel = DatabaseOptional
DBPath = ${pacman_dbpath}
CacheDir = ${pacman_cachedir}
GPGDir = ${PACSTRAP_GPGDIR}

[core]
Include = mirrorlist

[extra]
Include = mirrorlist
EOF

  echo "Server = ${MIRROR}" >mirrorlist

  pacstrap -C pacman.conf -M \
    "${MOUNT}" \
    base linux grub openssh sudo btrfs-progs dosfstools efibootmgr \
    qemu-guest-agent curl ca-certificates gnupg mkinitcpio iptables-nft

  gpgconf --homedir "${MOUNT}/etc/pacman.d/gnupg" --kill gpg-agent || true
  cp mirrorlist "${MOUNT}/etc/pacman.d/"
}

function image_cleanup() {
  rm -rf "${MOUNT}/etc/pacman.d/gnupg/"

  arch-chroot "${MOUNT}" /usr/bin/mkinitcpio -p linux -- -S autodetect

  sync -f "${MOUNT}/etc/os-release"
  fstrim --verbose "${MOUNT}"
  fstrim --verbose "${MOUNT}/efi" || true
}

function mount_image() {
  LOOPDEV="$(losetup --find --partscan --show "${1:-${IMAGE}}")"
  wait_until_settled "${LOOPDEV}"

  mount -o compress=zstd:1 "${LOOPDEV}p3" "${MOUNT}"

  if [ -d /var/cache/pacman/pkg ]; then
    mount --mkdir --bind /var/cache/pacman/pkg "${MOUNT}/var/cache/pacman/pkg"
  fi
}

function unmount_image() {
  if mountpoint -q "${MOUNT}"; then
    umount --recursive "${MOUNT}"
  fi

  if [ -n "${LOOPDEV:-}" ]; then
    losetup -d "${LOOPDEV}"
    LOOPDEV=""
  fi
}

function mv_to_output() {
  sha256sum "${1}" >"${1}.SHA256"

  if [ -n "${SUDO_UID:-}" ] && [ -n "${SUDO_GID:-}" ]; then
    chown "${SUDO_UID}:${SUDO_GID}" "${1}" "${1}.SHA256"
  fi

  mv "${1}" "${1}.SHA256" "${OUTPUT}/"
}

function create_image() {
  local tmp_image

  log_step "Preparing final image layout"
  tmp_image="$(basename "$(mktemp -u --tmpdir="${PWD}" image.XXXXXXXXXX.raw)")"
  cp -a "${IMAGE}" "${tmp_image}"

  if [ -n "${DISK_SIZE}" ]; then
    truncate -s "${DISK_SIZE}" "${tmp_image}"
    sgdisk --align-end --delete 3 "${tmp_image}"
    sgdisk --align-end --move-second-header \
      --new 0:0:0 --typecode=0:8304 --change-name=0:'Arch Linux root' \
      "${tmp_image}"
  fi

  mount_image "${tmp_image}"

  if [ -n "${DISK_SIZE}" ]; then
    log_step "Resizing final image filesystem"
    btrfs filesystem resize max "${MOUNT}"
  fi

  if [ "${#PACKAGES[@]}" -gt 0 ]; then
    log_step "Installing final image packages"
    arch-chroot "${MOUNT}" /usr/bin/pacman -S --noconfirm --needed --noprogressbar --color never "${PACKAGES[@]}"
  fi

  if [ "${#SERVICES[@]}" -gt 0 ]; then
    log_step "Enabling final image services"
    arch-chroot "${MOUNT}" /usr/bin/systemctl enable "${SERVICES[@]}"
  fi

  log_step "Applying BlackArch cloud customizations"
  pre
  log_step "Cleaning image for distribution"
  image_cleanup
  unmount_image

  log_step "Converting raw image to qcow2"
  post "${tmp_image}" "${1}"
  log_step "Writing checksum and moving artifacts"
  mv_to_output "${1}"
}

function main() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "root is required"
    exit 1
  fi

  resolve_build_version "${1:-}"
  setup_logging

  log_step "Initializing build workspace"
  init

  log_step "Creating raw disk image"
  setup_disk

  log_step "Bootstrapping Arch Linux base system"
  bootstrap

  # shellcheck source=images/base.sh
  source "${PROJECT_ROOT}/images/base.sh"
  log_step "Applying base image customizations"
  pre
  unmount_image

  # shellcheck source=images/blackarch-cloud.sh
  source "${PROJECT_ROOT}/images/blackarch-cloud.sh"
  create_image "${IMAGE_NAME}"

  log_step "Build completed"
  status_line "Artifacts saved to: ${OUTPUT}"
  status_line "Image: ${OUTPUT}/${IMAGE_NAME}"
  status_line "Checksum: ${OUTPUT}/${IMAGE_NAME}.SHA256"
  status_line "Build log: ${BUILD_LOG}"
}
main "${1:-}"
