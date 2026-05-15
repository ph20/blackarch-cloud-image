#!/usr/bin/env bash

readonly WEEKLY_DEFAULT_IMAGE_PROFILES="generic-qemu digitalocean hetzner"
readonly WEEKLY_SUDO_PRESERVE_ENV="IMAGE_PROFILE,IMAGE_PROFILES,BUILD_ID,BUILD_VERSION,BUILD_WORKSPACE,OUTPUT_ROOT,TMP_ROOT,BUILD_WORKDIR,REUSE_ROOTFS,DEFAULT_DISK_SIZE,DISK_SIZE,BLACKARCH_PROFILE,BLACKARCH_PACKAGES,BLACKARCH_KEYRING_VERSION,BLACKARCH_KEYRING_SHA256,BLACKARCH_STRAP_URL,BLACKARCH_STRAP_SHA256,IMAGE_ENABLE_QEMU_GUEST_AGENT,IMAGE_HOSTNAME,IMAGE_SWAP_SIZE,IMAGE_LOCALE,IMAGE_TIMEZONE,IMAGE_KEYMAP,IMAGE_DEFAULT_USER,IMAGE_DEFAULT_USER_GECOS,IMAGE_PASSWORDLESS_SUDO"

function weekly_die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

function weekly_need_cmd() {
  command -v "$1" >/dev/null 2>&1 || weekly_die "Missing required command: $1"
}

function weekly_validate_build_id() {
  [[ "${1}" =~ ^[0-9]{8}\.[0-9]+$ ]]
}

function weekly_requested_profiles() {
  printf '%s\n' "${IMAGE_PROFILES:-${WEEKLY_DEFAULT_IMAGE_PROFILES}}"
}

function weekly_path_env_prefix() {
  local -a entries=()
  local var=''
  local value=''

  for var in BUILD_WORKSPACE OUTPUT_ROOT TMP_ROOT; do
    value="${!var:-}"
    if [ -n "${value}" ]; then
      entries+=("$(printf '%s=%q' "${var}" "${value}")")
    fi
  done

  if [ "${#entries[@]}" -gt 0 ]; then
    printf '%s ' "${entries[*]}"
  fi
}

function weekly_resolve_build_id() {
  local script_dir="${1}"
  local positional_build_id="${2}"
  local dry_run="${3}"
  local resolved=''

  if [ -n "${positional_build_id}" ] && [ -n "${BUILD_ID:-}" ] && [ "${positional_build_id}" != "${BUILD_ID}" ]; then
    weekly_die "Positional BUILD_ID and environment BUILD_ID must match (${positional_build_id} vs ${BUILD_ID})"
  fi

  if [ -n "${positional_build_id}" ]; then
    resolved="${positional_build_id}"
  elif [ -n "${BUILD_ID:-}" ]; then
    resolved="${BUILD_ID}"
  else
    if [ "${dry_run}" -eq 1 ]; then
      resolved="$("${script_dir}/next-build-id-r2.sh" --channel weekly --dry-run)"
    else
      resolved="$("${script_dir}/next-build-id-r2.sh" --channel weekly)"
    fi
  fi

  weekly_validate_build_id "${resolved}" || weekly_die "Invalid BUILD_ID: ${resolved}"
  printf '%s\n' "${resolved}"
}

function weekly_run_multi_profile_build() {
  local script_dir="${1}"
  local build_id="${2}"
  local profiles="${3}"

  if [ "$(id -u)" -eq 0 ]; then
    IMAGE_PROFILES="${profiles}" BUILD_ID="${build_id}" BUILD_VERSION="${build_id}" \
      "${script_dir}/build-all-profiles.sh" "${build_id}"
  else
    printf '%s\n' 'Root access is required to build images. Any publish step can continue as the current user after the build.'
    IMAGE_PROFILES="${profiles}" BUILD_ID="${build_id}" BUILD_VERSION="${build_id}" \
      sudo --preserve-env="${WEEKLY_SUDO_PRESERVE_ENV}" \
      -p '[sudo] Enter your password to continue the BlackArch weekly image build for %p: ' \
      "${script_dir}/build-all-profiles.sh" "${build_id}"
  fi
}

function weekly_print_publish_commands() {
  local build_id="${1}"
  local path_env_prefix=''

  path_env_prefix="$(weekly_path_env_prefix)"

  printf '\n'
  printf '%s\n' 'Publish this build with:'
  printf '  %sBUILD_ID=%s make publish-dry-run\n' "${path_env_prefix}" "${build_id}"
  printf '  %sBUILD_ID=%s make publish\n' "${path_env_prefix}" "${build_id}"
  printf '%s\n' 'Equivalent direct command:'
  printf '  %sbash ./scripts/publish-r2.sh --channel weekly --build-id %s --promote-latest\n' "${path_env_prefix}" "${build_id}"
}
