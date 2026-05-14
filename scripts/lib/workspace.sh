#!/usr/bin/env bash

function resolve_project_path() {
  local path="${1}"

  case "${path}" in
    /*)
      printf '%s\n' "${path}"
      ;;
    *)
      printf '%s/%s\n' "${PROJECT_ROOT}" "${path}"
      ;;
  esac
}

function workspace_nearest_existing_path() {
  local path="${1}"

  while [ ! -e "${path}" ] && [ "${path}" != "/" ]; do
    path="$(dirname "${path}")"
  done

  printf '%s\n' "${path}"
}

function workspace_path_details() {
  local path="${1}"

  if command -v stat >/dev/null 2>&1; then
    stat -c 'owner=%U:%G mode=%A' "${path}" 2>/dev/null || printf '%s\n' 'owner/mode unavailable'
    return 0
  fi

  printf '%s\n' 'owner/mode unavailable'
}

function workspace_fail() {
  printf '%s\n' "${1}" >&2
  return 1
}

function workspace_require_existing_dir() {
  local path="${1}"
  local label="${2}"

  if [ -d "${path}" ]; then
    return 0
  fi

  if [ -e "${path}" ]; then
    workspace_fail "${label} must be a directory (got: ${path})"
    return 1
  fi

  workspace_fail "${label} must be an existing directory (got: ${path})"
}

function workspace_require_writable_dir() {
  local path="${1}"
  local label="${2}"
  local probe_path="${path}/.blackarch-write-test.$$"
  local path_details=''

  if (umask 077 && : >"${probe_path}") 2>/dev/null; then
    rm -f "${probe_path}"
    return 0
  fi

  path_details="$(workspace_path_details "${path}")"
  workspace_fail "${label} must be writable by the current user (got: ${path}, ${path_details})"
}

function workspace_require_usable_dir_target() {
  local path="${1}"
  local label="${2}"
  local parent=''

  if [ -e "${path}" ]; then
    workspace_require_existing_dir "${path}" "${label}" || return 1
    workspace_require_writable_dir "${path}" "${label}" || return 1
    return 0
  fi

  parent="$(workspace_nearest_existing_path "$(dirname "${path}")")"
  workspace_require_existing_dir "${parent}" "parent directory for ${label}" || return 1
  workspace_require_writable_dir "${parent}" "parent directory for ${label}" || return 1
}

function validate_build_workspace_configuration() {
  workspace_require_existing_dir "${BUILD_WORKSPACE}" "BUILD_WORKSPACE" || return 1
  workspace_require_writable_dir "${BUILD_WORKSPACE}" "BUILD_WORKSPACE" || return 1
  workspace_require_usable_dir_target "${OUTPUT_ROOT}" "OUTPUT_ROOT" || return 1
  workspace_require_usable_dir_target "${ROOTFS_OUTPUT_DIR}" "ROOTFS_OUTPUT_DIR" || return 1
  workspace_require_usable_dir_target "${IMAGE_OUTPUT_DIR}" "IMAGE_OUTPUT_DIR" || return 1
  workspace_require_usable_dir_target "${TMP_ROOT}" "TMP_ROOT" || return 1
  workspace_require_usable_dir_target "${BUILD_WORKDIR}" "BUILD_WORKDIR" || return 1
}
