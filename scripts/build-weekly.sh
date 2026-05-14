#!/usr/bin/env bash

set -o nounset
set -o errexit
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
readonly PROJECT_ROOT

# shellcheck source=scripts/lib/weekly.sh
source "${SCRIPT_DIR}/lib/weekly.sh"

DRY_RUN=0
POSITIONAL_BUILD_ID=""

function usage() {
  cat <<'EOF'
Usage: scripts/build-weekly.sh [options] [BUILD_ID]

Build the configured weekly image profiles without publishing.

Options:
  --dry-run     Print the planned build and publish commands only
  -h, --help    Show this help

Environment:
  BUILD_ID          Optional explicit YYYYMMDD.N build ID
  IMAGE_PROFILES   Space-separated profile list (default: generic-qemu digitalocean)
EOF
}

function parse_args() {
  while [ "$#" -gt 0 ]; do
    case "${1}" in
      --dry-run)
        DRY_RUN=1
        ;;
      -h | --help)
        usage
        exit 0
        ;;
      -*)
        weekly_die "Unknown option: ${1}"
        ;;
      *)
        [ -z "${POSITIONAL_BUILD_ID}" ] || weekly_die 'Only one positional BUILD_ID is supported'
        POSITIONAL_BUILD_ID="${1}"
        ;;
    esac
    shift
  done
}

function print_dry_run_plan() {
  local build_id="${1}"
  local profiles="${2}"

  printf '%s\n' 'DRY-RUN: no build or R2 upload will be performed.'
  printf 'Build ID: %s\n' "${build_id}"
  printf 'Profiles: %s\n' "${profiles}"
  printf 'Build command: IMAGE_PROFILES=%q BUILD_ID=%q make build-all\n' "${profiles}" "${build_id}"
  weekly_print_publish_commands "${build_id}"
}

function main() {
  local build_id=''
  local profiles=''

  parse_args "$@"
  build_id="$(weekly_resolve_build_id "${SCRIPT_DIR}" "${POSITIONAL_BUILD_ID}" "${DRY_RUN}")"
  profiles="$(weekly_requested_profiles)"

  if [ "${DRY_RUN}" -eq 1 ]; then
    print_dry_run_plan "${build_id}" "${profiles}"
    return 0
  fi

  cd "${PROJECT_ROOT}"
  weekly_run_multi_profile_build "${SCRIPT_DIR}" "${build_id}" "${profiles}"
  printf '\n'
  printf 'Weekly build completed for BUILD_ID=%s.\n' "${build_id}"
  weekly_print_publish_commands "${build_id}"
}

main "$@"
