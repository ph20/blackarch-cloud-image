#!/usr/bin/env bash

function require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    printf '%s\n' 'root is required' >&2
    exit 1
  fi
}

function chown_to_invoking_user() {
  if [ -z "${SUDO_UID:-}" ] || [ -z "${SUDO_GID:-}" ]; then
    return 0
  fi

  chown "${SUDO_UID}:${SUDO_GID}" "${@}"
}

function ensure_directories() {
  mkdir -p "${@}"
  chown_to_invoking_user "${@}" 2>/dev/null || true
}

function current_timestamp_utc() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}
