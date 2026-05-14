#!/usr/bin/env bash

set -o nounset
set -o errexit
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

# shellcheck source=scripts/lib/r2.sh
source "${SCRIPT_DIR}/lib/r2.sh"

CHANNEL="weekly"
BUILD_DATE="$(date -u +%Y%m%d)"
DRY_RUN=0

declare -a AWS_CMD=()
declare -a AWS_EXTRA_ARGS=()

function usage() {
  cat <<'EOF'
Usage: scripts/next-build-id-r2.sh [options]

Return the next R2-backed BlackArch image build ID for a date.

Options:
  --date YYYYMMDD           Build date to inspect (default: current UTC date)
  --channel weekly|releases Channel to inspect (default: weekly)
  --dry-run                 Print the intended query and return YYYYMMDD.0
  -h, --help                Show this help
EOF
}

function warn() {
  printf 'WARNING: %s\n' "$*" >&2
}

function die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

function validate_channel() {
  case "${1}" in
    weekly | releases)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

function validate_date() {
  [[ "${1}" =~ ^[0-9]{8}$ ]]
}

function parse_args() {
  while [ "$#" -gt 0 ]; do
    case "${1}" in
      --date)
        [ "$#" -ge 2 ] || die '--date requires a value'
        BUILD_DATE="${2}"
        shift
        ;;
      --channel)
        [ "$#" -ge 2 ] || die '--channel requires a value'
        CHANNEL="${2}"
        shift
        ;;
      --dry-run)
        DRY_RUN=1
        ;;
      -h | --help)
        usage
        exit 0
        ;;
      *)
        die "Unknown option: ${1}"
        ;;
    esac
    shift
  done
}

function has_required_r2_config() {
  [ -n "${R2_BUCKET:-}" ] && [ -n "${R2_ENDPOINT_URL:-}" ] && [ -n "${R2_PUBLIC_BASE_URL:-}" ]
}

function aws_base_command() {
  AWS_CMD=(aws --endpoint-url "${R2_ENDPOINT_URL}")
  if [ -n "${AWS_PROFILE:-}" ]; then
    AWS_CMD+=(--profile "${AWS_PROFILE}")
  fi
  if [ -n "${AWS_CLI_EXTRA_ARGS:-}" ]; then
    # shellcheck disable=SC2206
    AWS_EXTRA_ARGS=(${AWS_CLI_EXTRA_ARGS})
    AWS_CMD+=("${AWS_EXTRA_ARGS[@]}")
  fi
}

function dry_default() {
  local prefix="${1}"
  local reason="${2}"

  warn "${reason}"
  warn "Would query s3://${R2_BUCKET:-<R2_BUCKET>}/${prefix}"
  printf '%s.0\n' "${BUILD_DATE}"
}

function next_from_r2() {
  local year="${BUILD_DATE:0:4}"
  local prefix="blackarch/images/${CHANNEL}/${year}/${BUILD_DATE}."
  local keys=''
  local key=''
  local max=-1
  local release=0

  if [ "${DRY_RUN}" -eq 1 ]; then
    dry_default "${prefix}" 'Dry-run requested; not querying R2'
    return 0
  fi

  if ! has_required_r2_config; then
    dry_default "${prefix}" 'R2 config is missing; not querying R2'
    return 0
  fi

  if ! command -v aws >/dev/null 2>&1; then
    die 'Missing required command for R2 object listing: aws'
  fi

  aws_base_command
  keys="$("${AWS_CMD[@]}" s3api list-objects-v2 \
    --bucket "${R2_BUCKET}" \
    --prefix "${prefix}" \
    --query 'Contents[].Key' \
    --output text)"

  for key in ${keys}; do
    if [[ "${key}" =~ ^blackarch/images/${CHANNEL}/${year}/(${BUILD_DATE}\.([0-9]+))/ ]]; then
      release="${BASH_REMATCH[2]}"
      if [ "${release}" -gt "${max}" ]; then
        max="${release}"
      fi
    fi
  done

  printf '%s.%s\n' "${BUILD_DATE}" "$((max + 1))"
}

function main() {
  parse_args "$@"
  validate_date "${BUILD_DATE}" || die "Invalid date: ${BUILD_DATE}"
  validate_channel "${CHANNEL}" || die "Invalid channel: ${CHANNEL}"
  export R2_DRY_RUN="${DRY_RUN}"
  next_from_r2
}

main "$@"
