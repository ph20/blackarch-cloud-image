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

# shellcheck source=scripts/lib/validation.sh
source "${PROJECT_ROOT}/scripts/lib/validation.sh"

readonly RESOLVED_BLACKARCH_PROFILE="${BLACKARCH_PROFILE:-core}"
readonly RESOLVED_BLACKARCH_KEYRING_VERSION="${BLACKARCH_KEYRING_VERSION:-${DEFAULT_BLACKARCH_KEYRING_VERSION}}"
readonly RESOLVED_FINAL_DISK_SIZE="${DISK_SIZE:-${DEFAULT_DISK_SIZE}}"
readonly RESOLVED_IMAGE_HOSTNAME="${IMAGE_HOSTNAME:-blackarch}"
readonly RESOLVED_IMAGE_SWAP_SIZE="${IMAGE_SWAP_SIZE:-512m}"
readonly RESOLVED_IMAGE_LOCALE="${IMAGE_LOCALE:-C.UTF-8}"
readonly RESOLVED_IMAGE_TIMEZONE="${IMAGE_TIMEZONE:-UTC}"
readonly RESOLVED_IMAGE_KEYMAP="${IMAGE_KEYMAP:-us}"
readonly RESOLVED_IMAGE_DEFAULT_USER="${IMAGE_DEFAULT_USER:-arch}"
readonly RESOLVED_IMAGE_DEFAULT_USER_GECOS="${IMAGE_DEFAULT_USER_GECOS:-BlackArch Cloud User}"
readonly RESOLVED_IMAGE_PASSWORDLESS_SUDO="${IMAGE_PASSWORDLESS_SUDO:-true}"
readonly RESOLVED_IMAGE_ENABLE_QEMU_GUEST_AGENT="${IMAGE_ENABLE_QEMU_GUEST_AGENT:-false}"

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

function next_default_build_version() {
  local build_date=''
  local file_name=''
  local version_tail=''
  local release=''
  local max_release=-1
  local path=''

  build_date="$(date +%Y%m%d)"

  if [ -d "${OUTPUT}" ]; then
    shopt -s nullglob

    for path in "${OUTPUT}/${IMAGE_NAME_PREFIX}-${build_date}."*; do
      file_name="$(basename "${path}")"
      version_tail="${file_name#"${IMAGE_NAME_PREFIX}"-}"

      if [[ "${version_tail}" =~ ^${build_date}\.([0-9]+)(\.|$) ]]; then
        release="${BASH_REMATCH[1]}"

        if [ "${release}" -gt "${max_release}" ]; then
          max_release="${release}"
        fi
      fi
    done

    shopt -u nullglob
  fi

  printf '%s.%s\n' "${build_date}" "$((max_release + 1))"
}

function resolve_build_version() {
  if [ -n "${1:-}" ]; then
    build_version="${1}"
    build_version_was_defaulted=0
  elif [ -n "${BUILD_VERSION:-}" ]; then
    build_version="${BUILD_VERSION}"
    build_version_was_defaulted=0
  else
    build_version="$(next_default_build_version)"
    build_version_was_defaulted=1
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
    status_line "No explicit build version was provided."
    status_line "Auto-selected build version ${build_version}"
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
    chown "${SUDO_UID}:${SUDO_GID}" "${OUTPUT}" "${TMP_ROOT}" "${TMPDIR}"
  fi

  cd "${TMPDIR}"
  readonly MOUNT="${PWD}/mount"
  mkdir "${MOUNT}"
}

function cleanup() {
  set +o errexit

  if [ -n "${MOUNT:-}" ]; then
    unmount_mount_tree "${MOUNT}" || true
  fi

  if [ -n "${LOOPDEV:-}" ]; then
    detach_loop_device "${LOOPDEV}" || true
  fi

  if [ -n "${TMPDIR:-}" ] && [ -d "${TMPDIR}" ]; then
    rm -rf "${TMPDIR}"
  fi
}
trap cleanup EXIT

function unmount_mount_tree() {
  local mount_root="${1}"

  if ! mountpoint -q "${mount_root}"; then
    return 0
  fi

  if umount --recursive "${mount_root}"; then
    return 0
  fi

  status_line "Standard unmount failed for ${mount_root}; retrying with lazy unmount."
  umount --recursive --lazy "${mount_root}"
}

function detach_loop_device() {
  local loop_device="${1}"
  local retries=3

  while [ "${retries}" -gt 0 ]; do
    if losetup -d "${loop_device}" 2>/dev/null; then
      return 0
    fi

    udevadm settle || true
    sleep 1
    retries=$((retries - 1))
  done

  losetup -d "${loop_device}"
}

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
  local -a bootstrap_packages=(
    base
    linux
    grub
    openssh
    sudo
    btrfs-progs
    dosfstools
    efibootmgr
    curl
    ca-certificates
    gnupg
    mkinitcpio
    iptables-nft
  )

  mkdir -p "${pacman_dbpath}" "${pacman_cachedir}"

  if [ "${RESOLVED_IMAGE_ENABLE_QEMU_GUEST_AGENT}" = "true" ]; then
    bootstrap_packages+=(qemu-guest-agent)
  fi

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
    "${bootstrap_packages[@]}"

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
  unmount_mount_tree "${MOUNT}"

  if [ -n "${LOOPDEV:-}" ]; then
    detach_loop_device "${LOOPDEV}"
    LOOPDEV=""
  fi
}

function mv_to_output() {
  local image_path="${1}"
  local manifest_path=''

  manifest_path="$(write_manifest "${image_path}")"
  sha256sum "${image_path}" >"${image_path}.SHA256"

  if [ -n "${SUDO_UID:-}" ] && [ -n "${SUDO_GID:-}" ]; then
    chown "${SUDO_UID}:${SUDO_GID}" "${image_path}" "${image_path}.SHA256" "${manifest_path}"
  fi

  mv "${image_path}" "${image_path}.SHA256" "${manifest_path}" "${OUTPUT}/"
}

function write_manifest_entry() {
  local manifest_path="${1}"
  local key="${2}"
  local value="${3}"

  printf '%s=%q\n' "${key}" "${value}" >>"${manifest_path}"
}

function write_manifest() {
  local image_path="${1}"
  local manifest_path="${image_path%.qcow2}.manifest"
  local bootstrap_mode='built-in'
  local strap_sha256_set='false'
  local keyring_sha256_source='pinned'

  if [ -n "${BLACKARCH_STRAP_URL:-}" ]; then
    bootstrap_mode='legacy-custom-strap'
    strap_sha256_set='true'
  fi

  if [ -n "${BLACKARCH_KEYRING_SHA256:-}" ]; then
    keyring_sha256_source='env'
  fi

  : > "${manifest_path}"
  write_manifest_entry "${manifest_path}" "BUILD_VERSION" "${build_version}"
  write_manifest_entry "${manifest_path}" "IMAGE_NAME" "${IMAGE_NAME}"
  write_manifest_entry "${manifest_path}" "DEFAULT_DISK_SIZE" "${DEFAULT_DISK_SIZE}"
  write_manifest_entry "${manifest_path}" "FINAL_DISK_SIZE" "${RESOLVED_FINAL_DISK_SIZE}"
  write_manifest_entry "${manifest_path}" "BLACKARCH_PROFILE" "${RESOLVED_BLACKARCH_PROFILE}"
  write_manifest_entry "${manifest_path}" "BLACKARCH_PACKAGES" "${BLACKARCH_PACKAGES:-}"
  write_manifest_entry "${manifest_path}" "IMAGE_HOSTNAME" "${RESOLVED_IMAGE_HOSTNAME}"
  write_manifest_entry "${manifest_path}" "IMAGE_DEFAULT_USER" "${RESOLVED_IMAGE_DEFAULT_USER}"
  write_manifest_entry "${manifest_path}" "IMAGE_DEFAULT_USER_GECOS" "${RESOLVED_IMAGE_DEFAULT_USER_GECOS}"
  write_manifest_entry "${manifest_path}" "IMAGE_LOCALE" "${RESOLVED_IMAGE_LOCALE}"
  write_manifest_entry "${manifest_path}" "IMAGE_TIMEZONE" "${RESOLVED_IMAGE_TIMEZONE}"
  write_manifest_entry "${manifest_path}" "IMAGE_KEYMAP" "${RESOLVED_IMAGE_KEYMAP}"
  write_manifest_entry "${manifest_path}" "IMAGE_SWAP_SIZE" "${RESOLVED_IMAGE_SWAP_SIZE}"
  write_manifest_entry "${manifest_path}" "IMAGE_PASSWORDLESS_SUDO" "${RESOLVED_IMAGE_PASSWORDLESS_SUDO}"
  write_manifest_entry "${manifest_path}" "IMAGE_ENABLE_QEMU_GUEST_AGENT" "${RESOLVED_IMAGE_ENABLE_QEMU_GUEST_AGENT}"
  write_manifest_entry "${manifest_path}" "BLACKARCH_KEYRING_VERSION" "${RESOLVED_BLACKARCH_KEYRING_VERSION}"
  write_manifest_entry "${manifest_path}" "BLACKARCH_KEYRING_SHA256_SOURCE" "${keyring_sha256_source}"
  write_manifest_entry "${manifest_path}" "BLACKARCH_BOOTSTRAP_MODE" "${bootstrap_mode}"
  write_manifest_entry "${manifest_path}" "BLACKARCH_STRAP_URL" "${BLACKARCH_STRAP_URL:-}"
  write_manifest_entry "${manifest_path}" "BLACKARCH_STRAP_SHA256_SET" "${strap_sha256_set}"

  printf '%s\n' "${manifest_path}"
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
  validate_build_configuration "${build_version}"
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
  status_line "Manifest: ${OUTPUT}/${IMAGE_NAME%.qcow2}.manifest"
  status_line "Build log: ${BUILD_LOG}"
}
main "${1:-}"
