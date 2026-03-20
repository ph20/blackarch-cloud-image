#!/usr/bin/env bash

readonly DEFAULT_BLACKARCH_KEYRING_VERSION="20251011"
readonly MIN_IMAGE_SIZE_BYTES=$((2 * 1024 * 1024 * 1024))

function validation_fail() {
  echo "${1}" >&2
  return 1
}

function lookup_pinned_blackarch_keyring_sha256() {
  case "${1}" in
    20251011)
      printf '%s\n' 'e4934a37b018dda1df6403147c11c3e8efdc543419f10be485c7836e19f3cfbe'
      ;;
    *)
      return 1
      ;;
  esac
}

function is_sha256_value() {
  [[ "${1}" =~ ^[0-9A-Fa-f]{64}$ ]]
}

function parse_size_to_bytes() {
  local size_value=''

  size_value="${1^^}"

  if ! [[ "${size_value}" =~ ^[0-9]+([KMGTPE])?$ ]]; then
    return 1
  fi

  numfmt --from=iec "${size_value}"
}

function validate_build_version_value() {
  local build_version="${1:-}"

  if [ -z "${build_version}" ]; then
    return 0
  fi

  if [[ "${build_version}" =~ ^[0-9]{8}\.[0-9]+$ ]]; then
    return 0
  fi

  validation_fail "BUILD_VERSION must match YYYYMMDD.N (got: ${build_version})"
}

function validate_size_value() {
  local env_name="${1}"
  local size_value="${2:-}"
  local size_bytes=''

  if [ -z "${size_value}" ]; then
    return 0
  fi

  if ! size_bytes="$(parse_size_to_bytes "${size_value}")"; then
    validation_fail "${env_name} must be a truncate-compatible size such as 2G or 512M (got: ${size_value})"
    return 1
  fi

  if [ "${size_bytes}" -lt "${MIN_IMAGE_SIZE_BYTES}" ]; then
    validation_fail "${env_name} must be at least 2G (got: ${size_value})"
    return 1
  fi
}

function validate_blackarch_profile_value() {
  local profile="${1:-core}"

  case "${profile}" in
    core | common)
      return 0
      ;;
    *)
      validation_fail "BLACKARCH_PROFILE must be one of: core, common (got: ${profile})"
      return 1
      ;;
  esac
}

function validate_blackarch_bootstrap_configuration() {
  local keyring_version="${BLACKARCH_KEYRING_VERSION:-${DEFAULT_BLACKARCH_KEYRING_VERSION}}"

  if [ -n "${BLACKARCH_KEYRING_VERSION:-}" ] && ! [[ "${BLACKARCH_KEYRING_VERSION}" =~ ^[0-9]{8}$ ]]; then
    validation_fail "BLACKARCH_KEYRING_VERSION must match YYYYMMDD (got: ${BLACKARCH_KEYRING_VERSION})"
    return 1
  fi

  if [ -n "${BLACKARCH_KEYRING_SHA256:-}" ] && ! is_sha256_value "${BLACKARCH_KEYRING_SHA256}"; then
    validation_fail "BLACKARCH_KEYRING_SHA256 must be a 64-character SHA256 hex string"
    return 1
  fi

  if [ -n "${BLACKARCH_STRAP_URL:-}" ]; then
    if ! [[ "${BLACKARCH_STRAP_URL}" =~ ^https:// ]]; then
      validation_fail "BLACKARCH_STRAP_URL must use https://"
      return 1
    fi

    if [ -z "${BLACKARCH_STRAP_SHA256:-}" ]; then
      validation_fail "BLACKARCH_STRAP_SHA256 is required when BLACKARCH_STRAP_URL is set"
      return 1
    fi
  elif [ -n "${BLACKARCH_STRAP_SHA256:-}" ]; then
    validation_fail "BLACKARCH_STRAP_SHA256 requires BLACKARCH_STRAP_URL"
    return 1
  fi

  if [ -n "${BLACKARCH_STRAP_SHA256:-}" ] && ! is_sha256_value "${BLACKARCH_STRAP_SHA256}"; then
    validation_fail "BLACKARCH_STRAP_SHA256 must be a 64-character SHA256 hex string"
    return 1
  fi

  if [ -n "${BLACKARCH_KEYRING_SHA256:-}" ]; then
    return 0
  fi

  if lookup_pinned_blackarch_keyring_sha256 "${keyring_version}" >/dev/null; then
    return 0
  fi

  validation_fail "BLACKARCH_KEYRING_SHA256 is required for BLACKARCH_KEYRING_VERSION=${keyring_version}"
}

function validate_build_configuration() {
  local build_version="${1:-}"

  validate_build_version_value "${build_version}" || return 1
  validate_size_value "DEFAULT_DISK_SIZE" "${DEFAULT_DISK_SIZE:-2G}" || return 1
  validate_size_value "DISK_SIZE" "${DISK_SIZE:-}" || return 1
  validate_blackarch_profile_value "${BLACKARCH_PROFILE:-core}" || return 1
  validate_blackarch_bootstrap_configuration || return 1
}
