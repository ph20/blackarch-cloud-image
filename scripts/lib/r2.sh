#!/usr/bin/env bash

declare -a R2_AWS_CMD=()
declare -a R2_AWS_EXTRA_ARGS=()

function r2_is_dry_run() {
  [ "${R2_DRY_RUN:-0}" = "1" ]
}

function r2_warn() {
  printf 'WARNING: %s\n' "$*" >&2
}

function r2_error() {
  printf 'ERROR: %s\n' "$*" >&2
}

function r2_require_config() {
  local -a missing=()
  local var=''

  for var in R2_BUCKET R2_ENDPOINT_URL R2_PUBLIC_BASE_URL; do
    if [ -z "${!var:-}" ]; then
      missing+=("${var}")
    fi
  done

  if [ "${#missing[@]}" -eq 0 ]; then
    return 0
  fi

  if r2_is_dry_run; then
    r2_warn "Missing R2 config for dry-run: ${missing[*]}"
    return 0
  fi

  r2_error "Missing required R2 config: ${missing[*]}"
  return 1
}

function r2_require_publish_tools() {
  if r2_is_dry_run; then
    return 0
  fi

  if ! command -v aws >/dev/null 2>&1; then
    r2_error 'Missing required command for R2 publishing: aws'
    return 1
  fi
}

function r2_public_url_for_key() {
  local key="${1}"
  local base="${R2_PUBLIC_BASE_URL:-https://artifacts.ph20.org}"

  base="${base%/}"
  printf '%s/%s\n' "${base}" "${key}"
}

function r2_aws_base_command() {
  local profile="${AWS_PROFILE:-r2-ph20}"

  R2_AWS_CMD=(aws --endpoint-url "${R2_ENDPOINT_URL}")

  if [ -n "${profile}" ]; then
    R2_AWS_CMD+=(--profile "${profile}")
  fi

  if [ -n "${AWS_CLI_EXTRA_ARGS:-}" ]; then
    # shellcheck disable=SC2206
    R2_AWS_EXTRA_ARGS=(${AWS_CLI_EXTRA_ARGS})
    R2_AWS_CMD+=("${R2_AWS_EXTRA_ARGS[@]}")
  fi
}

function r2_head_object() {
  local key="${1}"

  r2_aws_base_command
  "${R2_AWS_CMD[@]}" s3api head-object \
    --bucket "${R2_BUCKET}" \
    --key "${key}" \
    >/dev/null 2>&1
}

function r2_cp_file() {
  local src="${1}"
  local key="${2}"
  local content_type="${3}"
  local cache_control="${4}"

  r2_aws_base_command
  "${R2_AWS_CMD[@]}" s3 cp "${src}" "s3://${R2_BUCKET}/${key}" \
    --content-type "${content_type}" \
    --cache-control "${cache_control}" \
    --only-show-errors \
    --no-progress
}

function r2_get_object_to_file() {
  local key="${1}"
  local dst="${2}"

  if ! r2_head_object "${key}"; then
    return 1
  fi

  r2_aws_base_command
  "${R2_AWS_CMD[@]}" s3 cp "s3://${R2_BUCKET}/${key}" "${dst}" \
    --only-show-errors \
    --no-progress
}

function r2_put_json_file() {
  local src="${1}"
  local key="${2}"

  r2_cp_file "${src}" "${key}" \
    "$(content_type_for_path "${key}")" \
    "$(cache_control_for_key_or_path "${key}")"
}

function content_type_for_path() {
  local path="${1}"

  case "${path}" in
    *.img.gz)
      printf '%s\n' 'application/gzip'
      ;;
    *.qcow2 | *.vmdk)
      printf '%s\n' 'application/octet-stream'
      ;;
    *.SHA256 | *.manifest | *.build.log | */SHA256SUMS)
      printf '%s\n' 'text/plain; charset=utf-8'
      ;;
    *.json)
      printf '%s\n' 'application/json; charset=utf-8'
      ;;
    *.asc)
      printf '%s\n' 'application/pgp-signature'
      ;;
    *)
      printf '%s\n' 'application/octet-stream'
      ;;
  esac
}

function cache_control_for_key_or_path() {
  local key="${1}"

  case "${key}" in
    blackarch/images/latest.json | blackarch/images/index.json)
      printf '%s\n' 'public, max-age=300'
      ;;
    *)
      if [[ "${key}" =~ ^blackarch/images/[^/]+/[0-9]{4}/[0-9]{8}\.[0-9]+/index\.json$ ]]; then
        printf '%s\n' 'public, max-age=3600'
      else
        printf '%s\n' 'public, max-age=31536000, immutable'
      fi
      ;;
  esac
}
