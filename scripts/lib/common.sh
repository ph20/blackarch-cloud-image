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
  run_logged mkdir -p "${@}"
  chown_to_invoking_user "${@}" 2>/dev/null || true
}

function current_timestamp_utc() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

function prepare_stage_workdir() {
  local stage_name="${1}"
  local stage_path=''

  if [ -z "${BUILD_WORKDIR:-}" ]; then
    BUILD_WORKDIR="${TMP_ROOT}/build-${BUILD_VERSION}-${IMAGE_PROFILE}"
    export BUILD_WORKDIR
  fi

  stage_path="${BUILD_WORKDIR}/${stage_name}"
  run_logged rm -rf "${stage_path}"
  run_logged mkdir -p "${stage_path}"
  printf '%s\n' "${stage_path}"
}
