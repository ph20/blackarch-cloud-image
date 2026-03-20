#!/usr/bin/env bash

set -o nounset
set -o errexit
set -o pipefail

readonly GIB=$((1024 * 1024 * 1024))
readonly DEFAULT_BLACKARCH_KEYRING_VERSION="20251011"
readonly ARCH_MIRROR_URL="https://fastly.mirror.pkgbuild.com/core/os/x86_64/core.db"
readonly BLACKARCH_MIRRORLIST_URL="https://blackarch.org/blackarch-mirrorlist"
readonly BLACKARCH_KEYRING_VERSION="${BLACKARCH_KEYRING_VERSION:-${DEFAULT_BLACKARCH_KEYRING_VERSION}}"
readonly BLACKARCH_KEYRING_URL="https://www.blackarch.org/keyring/blackarch-keyring-${BLACKARCH_KEYRING_VERSION}.tar.gz"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
readonly PROJECT_ROOT

FAILURES=0

function report_ok() {
  printf '[ok] %s\n' "${1}"
}

function report_fail() {
  printf '[fail] %s\n' "${1}" >&2
  FAILURES=$((FAILURES + 1))
}

function check_linux_host() {
  if [ "$(uname -s)" = "Linux" ]; then
    report_ok "host OS is Linux"
  else
    report_fail "host OS must be Linux"
  fi
}

function check_arch_family_host() {
  local os_id=''
  local os_like=''

  if [ ! -r /etc/os-release ]; then
    report_fail "cannot read /etc/os-release to detect the host distribution"
    return
  fi

  # shellcheck disable=SC1091
  source /etc/os-release
  os_id="${ID:-}"
  os_like="${ID_LIKE:-}"

  if printf '%s\n' "${os_id} ${os_like}" | grep -Eq '(^|[[:space:]])(arch|manjaro)($|[[:space:]])'; then
    report_ok "host distribution is Arch-based (${os_id:-unknown})"
  else
    report_fail "host distribution must be Arch-based; detected ID=${os_id:-unknown}, ID_LIKE=${os_like:-unset}"
  fi
}

function check_required_commands() {
  local -a required_commands=(
    arch-chroot
    blockdev
    btrfs
    chattr
    curl
    fstrim
    gpgconf
    losetup
    mkfs.btrfs
    mkfs.fat
    mount
    mountpoint
    pacman
    pacstrap
    qemu-img
    sha256sum
    sgdisk
    truncate
    udevadm
    umount
  )
  local -a missing_commands=()
  local cmd=''

  if [ "$(id -u)" -ne 0 ]; then
    required_commands+=(sudo)
  fi

  for cmd in "${required_commands[@]}"; do
    if ! command -v "${cmd}" >/dev/null 2>&1; then
      missing_commands+=("${cmd}")
    fi
  done

  if [ "${#missing_commands[@]}" -eq 0 ]; then
    report_ok "required host commands are installed"
  else
    report_fail "missing required host commands: ${missing_commands[*]}"
  fi
}

function check_privilege_escalation() {
  if [ "$(id -u)" -eq 0 ]; then
    report_ok "build is running as root"
    return
  fi

  if command -v sudo >/dev/null 2>&1; then
    report_ok "sudo is available; make will prompt for your password before privileged build steps"
  else
    report_fail "sudo is required when the build is not started as root"
  fi
}

function check_loop_device_support() {
  if [ -e /dev/loop-control ] || compgen -G '/dev/loop[0-9]*' >/dev/null; then
    report_ok "loop device support is available"
  else
    report_fail "loop devices are unavailable on the host"
  fi
}

function format_bytes() {
  numfmt --to=iec-i --suffix=B "${1}"
}

function estimate_required_free_space_bytes() {
  local required_bytes=$((8 * GIB))
  local profile="${BLACKARCH_PROFILE:-core}"

  # The build uses sparse raw images, so the estimate tracks package footprint
  # and temporary artifacts rather than the logical DISK_SIZE alone.
  case "${profile}" in
    core | '')
      ;;
    common)
      required_bytes=$((required_bytes + 4 * GIB))
      ;;
    *)
      required_bytes=$((required_bytes + 4 * GIB))
      ;;
  esac

  if [ -n "${BLACKARCH_PACKAGES:-}" ]; then
    required_bytes=$((required_bytes + 4 * GIB))
  fi

  printf '%s\n' "${required_bytes}"
}

function check_free_space() {
  local available_bytes=''
  local required_bytes=''
  local available_human=''
  local required_human=''
  local scope_description='for the selected build configuration'

  available_bytes="$(df --output=avail -B1 "${PROJECT_ROOT}" | awk 'NR == 2 { print $1 }')"

  if ! [[ "${available_bytes}" =~ ^[0-9]+$ ]]; then
    report_fail "cannot determine free space on ${PROJECT_ROOT}"
    return
  fi

  required_bytes="$(estimate_required_free_space_bytes)"
  available_human="$(format_bytes "${available_bytes}")"
  required_human="$(format_bytes "${required_bytes}")"

  if [ -n "${BLACKARCH_PACKAGES:-}" ]; then
    scope_description='for the selected build configuration with extra BlackArch packages'
  elif [ "${BLACKARCH_PROFILE:-core}" = "common" ]; then
    scope_description='for BLACKARCH_PROFILE=common'
  fi

  if [ "${available_bytes}" -ge "${required_bytes}" ]; then
    report_ok "workspace filesystem has ${available_human} free (estimated minimum ${required_human} ${scope_description})"
  else
    report_fail "workspace filesystem has ${available_human} free, below the estimated minimum ${required_human} ${scope_description}"
  fi
}

function check_url() {
  local label="${1}"
  local url="${2}"

  if curl \
    --fail \
    --show-error \
    --silent \
    --location \
    --proto '=https' \
    --tlsv1.2 \
    --connect-timeout 10 \
    --retry 2 \
    --output /dev/null \
    "${url}"; then
    report_ok "${label}"
  else
    report_fail "${label}: ${url}"
  fi
}

function check_network_access() {
  check_url "Arch package mirror is reachable" "${ARCH_MIRROR_URL}"

  if [ -n "${BLACKARCH_STRAP_URL:-}" ]; then
    check_url "configured external BlackArch strap is reachable" "${BLACKARCH_STRAP_URL}"
    return
  fi

  check_url "BlackArch mirrorlist is reachable" "${BLACKARCH_MIRRORLIST_URL}"
  check_url "BlackArch keyring archive is reachable" "${BLACKARCH_KEYRING_URL}"
}

function print_summary() {
  if [ "${FAILURES}" -eq 0 ]; then
    printf 'Preflight summary: all checks passed.\n'
    return
  fi

  printf 'Preflight summary: %s check(s) failed.\n' "${FAILURES}" >&2
  exit 1
}

function main() {
  check_linux_host
  check_arch_family_host
  check_required_commands
  check_privilege_escalation
  check_loop_device_support
  check_free_space
  check_network_access
  print_summary
}

main
