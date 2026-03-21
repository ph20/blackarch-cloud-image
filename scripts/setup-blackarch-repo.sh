#!/usr/bin/env bash

set -o nounset
set -o errexit
set -o pipefail

# Matches the keyring bundle version used by the official strap.sh snapshot.
readonly DEFAULT_BLACKARCH_KEYRING_VERSION="20251011"
readonly KEYRING_VERSION="${BLACKARCH_KEYRING_VERSION:-${DEFAULT_BLACKARCH_KEYRING_VERSION}}"
readonly KEYRING_ARCHIVE="blackarch-keyring-${KEYRING_VERSION}.tar.gz"
readonly KEYRING_URL="https://www.blackarch.org/keyring/${KEYRING_ARCHIVE}"
readonly MIRRORLIST_URL="https://blackarch.org/blackarch-mirrorlist"
readonly MIRRORLIST_PATH="/etc/pacman.d/blackarch-mirrorlist"
readonly PACMAN_CONF="/etc/pacman.conf"
readonly PACMAN_COMMAND_CONF="${BLACKARCH_PACMAN_CONFIG:-${PACMAN_CONF}}"
readonly PACMAN_KEYRING_DIR="/usr/share/pacman/keyrings"
WORKDIR="$(mktemp -d)"
readonly WORKDIR

function format_command_line() {
  local formatted=''
  local argument=''

  for argument in "${@}"; do
    if [ -n "${formatted}" ]; then
      formatted+=" "
    fi

    formatted+="$(printf '%q' "${argument}")"
  done

  printf '%s\n' "${formatted}"
}

function log_command() {
  printf '+ %s\n' "$(format_command_line "${@}")" >&2
}

function run_logged() {
  log_command "${@}"
  "${@}"
}

function cleanup() {
  rm -rf "${WORKDIR}"
}
trap cleanup EXIT

function pacman_refresh() {
  run_logged pacman --config "${PACMAN_COMMAND_CONF}" -Syy --noconfirm --noprogressbar --color never
}

function pacman_sync() {
  run_logged pacman --config "${PACMAN_COMMAND_CONF}" -S --noconfirm --needed --noprogressbar --color never "${@}"
}

function fail() {
  echo "${1}" >&2
  exit 1
}

function download_https() {
  local url="${1}"
  local destination="${2}"
  local tmp_path=''

  tmp_path="$(mktemp "${WORKDIR}/download.XXXXXX")"

  log_command curl \
    --fail \
    --show-error \
    --silent \
    --location \
    --proto '=https' \
    --tlsv1.2 \
    "${url}" \
    --output "${tmp_path}"

  curl \
    --fail \
    --show-error \
    --silent \
    --location \
    --proto '=https' \
    --tlsv1.2 \
    "${url}" \
    --output "${tmp_path}"

  run_logged mv "${tmp_path}" "${destination}"
}

function verify_sha256() {
  local file_path="${1}"
  local expected_sha256="${2}"
  local artifact_label="${3}"

  if ! echo "${expected_sha256}  ${file_path}" | sha256sum --check --status -; then
    fail "${artifact_label} SHA256 verification failed"
  fi
}

function resolve_keyring_sha256() {
  if [ -n "${BLACKARCH_KEYRING_SHA256:-}" ]; then
    printf '%s\n' "${BLACKARCH_KEYRING_SHA256}"
    return
  fi

  case "${KEYRING_VERSION}" in
    20251011)
      printf '%s\n' 'e4934a37b018dda1df6403147c11c3e8efdc543419f10be485c7836e19f3cfbe'
      ;;
    *)
      fail "BLACKARCH_KEYRING_SHA256 is required for BLACKARCH_KEYRING_VERSION=${KEYRING_VERSION}"
      ;;
  esac
}

function run_legacy_strap() {
  local strap_path="${WORKDIR}/strap.sh"
  local strap_url="${BLACKARCH_STRAP_URL}"

  if [ -z "${BLACKARCH_STRAP_SHA256:-}" ]; then
    fail "BLACKARCH_STRAP_SHA256 is required when BLACKARCH_STRAP_URL is set"
  fi

  download_https "${strap_url}" "${strap_path}"
  verify_sha256 "${strap_path}" "${BLACKARCH_STRAP_SHA256}" "BlackArch legacy strap"

  run_logged bash "${strap_path}"
}

function require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "root is required" >&2
    exit 1
  fi
}

function install_keyring() {
  local extracted_dir="${WORKDIR}/blackarch-keyring-${KEYRING_VERSION}"
  local keyring_archive_path="${WORKDIR}/${KEYRING_ARCHIVE}"
  local keyring_sha256=''

  keyring_sha256="$(resolve_keyring_sha256)"
  download_https "${KEYRING_URL}" "${keyring_archive_path}"
  verify_sha256 "${keyring_archive_path}" "${keyring_sha256}" "${KEYRING_ARCHIVE}"
  run_logged tar xzf "${keyring_archive_path}" -C "${WORKDIR}"

  run_logged install -Dm0644 \
    "${extracted_dir}/blackarch.gpg" \
    "${PACMAN_KEYRING_DIR}/blackarch.gpg"
  run_logged install -Dm0644 \
    "${extracted_dir}/blackarch-trusted" \
    "${PACMAN_KEYRING_DIR}/blackarch-trusted"
  run_logged install -Dm0644 \
    "${extracted_dir}/blackarch-revoked" \
    "${PACMAN_KEYRING_DIR}/blackarch-revoked"

  if [ ! -d /etc/pacman.d/gnupg ] || [ -z "$(find /etc/pacman.d/gnupg -mindepth 1 -maxdepth 1 2>/dev/null)" ]; then
    run_logged pacman-key --init
    run_logged pacman-key --populate archlinux
  fi

  run_logged pacman-key --populate blackarch
}

function install_mirrorlist() {
  local mirrorlist_path_tmp="${WORKDIR}/blackarch-mirrorlist"

  download_https "${MIRRORLIST_URL}" "${mirrorlist_path_tmp}"
  run_logged install -Dm0644 "${mirrorlist_path_tmp}" "${MIRRORLIST_PATH}"
}

function ensure_blackarch_repo_in_config() {
  local config_path="${1}"

  if grep -q '^\[blackarch\]$' "${config_path}"; then
    return
  fi

  cat >> "${config_path}" <<'EOF'
[blackarch]
Include = /etc/pacman.d/blackarch-mirrorlist
EOF
}

function ensure_blackarch_repo() {
  ensure_blackarch_repo_in_config "${PACMAN_CONF}"

  if [ "${PACMAN_COMMAND_CONF}" != "${PACMAN_CONF}" ]; then
    ensure_blackarch_repo_in_config "${PACMAN_COMMAND_CONF}"
  fi
}

function sync_blackarch_repo() {
  pacman_refresh
  pacman_sync blackarch-mirrorlist

  if [ -f /etc/pacman.d/blackarch-mirrorlist.pacnew ]; then
    mv /etc/pacman.d/blackarch-mirrorlist.pacnew /etc/pacman.d/blackarch-mirrorlist
  fi
}

function main() {
  require_root

  if [ -n "${BLACKARCH_STRAP_URL:-}" ]; then
    run_legacy_strap
    return
  fi

  if [ -n "${BLACKARCH_STRAP_SHA256:-}" ]; then
    fail "BLACKARCH_STRAP_SHA256 requires BLACKARCH_STRAP_URL"
  fi

  install_keyring
  install_mirrorlist
  ensure_blackarch_repo
  sync_blackarch_repo
}

main
