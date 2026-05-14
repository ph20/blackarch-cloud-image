#!/usr/bin/env bash

set -o nounset
set -o errexit
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
readonly PROJECT_ROOT

# shellcheck source=scripts/lib/config.sh
source "${SCRIPT_DIR}/lib/config.sh"

# shellcheck source=scripts/lib/r2.sh
source "${SCRIPT_DIR}/lib/r2.sh"

CHANNEL="weekly"
BUILD_ID=""
PROMOTE_LATEST=0
DRY_RUN=0
ALLOW_OVERWRITE=0
NO_SIGN=0
TMP_DIR=""
SHA256SUMS_PATH=""
SHA256SUMS_ASC_PATH=""
IMAGES_JSONL=""
BUILD_INDEX_PATH=""
ROOT_INDEX_PATH=""
EXISTING_ROOT_INDEX_PATH=""
PUBLISHED_AT_UTC=""
BUILD_RELEASE_VERSION=""
BUILD_ARTIFACT_VERSION=""
CURRENT_MANIFEST_PATH=""

declare -a IMMUTABLE_FILES=()
declare -a IMMUTABLE_KEYS=()
declare -a METADATA_FILES=()
declare -a METADATA_KEYS=()
declare -a METADATA_IMMUTABLE=()

function usage() {
  cat <<'EOF'
Usage: scripts/publish-r2.sh [options]

Publish selected BlackArch image build artifacts from the configured output/images to R2.

Options:
  --channel weekly|releases   Artifact channel (default: weekly)
  --build-id YYYYMMDD.N       Build ID to publish (required)
  --promote-latest            Upload blackarch/images/latest.json
  --dry-run                   Validate and print planned uploads only
  --allow-overwrite           Allow overwriting immutable object keys
  --no-sign                   Do not create or upload SHA256SUMS.asc
  -h, --help                  Show this help
EOF
}

function log() {
  printf '%s\n' "$*"
}

function warn() {
  printf 'WARNING: %s\n' "$*" >&2
}

function die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

function need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

function cleanup() {
  if [ -n "${TMP_DIR}" ] && [ -d "${TMP_DIR}" ]; then
    rm -rf "${TMP_DIR}"
  fi
}
trap cleanup EXIT

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

function validate_build_id() {
  [[ "${1}" =~ ^[0-9]{8}\.[0-9]+$ ]]
}

function parse_args() {
  while [ "$#" -gt 0 ]; do
    case "${1}" in
      --channel)
        [ "$#" -ge 2 ] || die '--channel requires a value'
        CHANNEL="${2}"
        shift
        ;;
      --build-id)
        [ "$#" -ge 2 ] || die '--build-id requires a value'
        BUILD_ID="${2}"
        shift
        ;;
      --promote-latest)
        PROMOTE_LATEST=1
        ;;
      --dry-run)
        DRY_RUN=1
        ;;
      --allow-overwrite)
        ALLOW_OVERWRITE=1
        ;;
      --no-sign)
        NO_SIGN=1
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

function require_manifest_field() {
  local field="${1}"

  if [ -z "${!field:-}" ]; then
    die "Manifest ${CURRENT_MANIFEST_PATH} is missing required field: ${field}"
  fi
}

function infer_arch() {
  local artifact_name="${1}"

  if [[ "${artifact_name}" =~ ^BlackArch-Linux-([^/-]+)- ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
    return 0
  fi

  warn "Could not infer arch from artifact name ${artifact_name}; using x86_64"
  printf '%s\n' 'x86_64'
}

function require_file() {
  local path="${1}"
  local label="${2}"

  [ -f "${path}" ] || die "Missing ${label}: ${path}"
}

function checksum_from_sha256_file() {
  local sha256_file="${1}"
  local checksum=''

  checksum="$(awk 'NR == 1 { print $1 }' "${sha256_file}")"
  if ! [[ "${checksum}" =~ ^[0-9A-Fa-f]{64}$ ]]; then
    die "Invalid SHA256 file: ${sha256_file}"
  fi

  printf '%s\n' "${checksum}"
}

function verify_artifact_checksum() {
  local sha256_file="${1}"

  (
    cd "${IMAGE_OUTPUT_DIR}"
    sha256sum -c "$(basename "${sha256_file}")"
  )
}

function build_log_for_manifest() {
  local manifest_build_log="${1}"
  local artifact_name="${2}"
  local artifact_format="${3}"
  local candidate=''
  local expected_build_log=''

  [ -n "${manifest_build_log}" ] || die "Manifest ${CURRENT_MANIFEST_PATH} is missing required field: image_build_log"
  expected_build_log="${artifact_name%."${artifact_format}"}.build.log"
  [ "${manifest_build_log}" = "${expected_build_log}" ] || die "Manifest ${CURRENT_MANIFEST_PATH} has image_build_log=${manifest_build_log}, expected ${expected_build_log}"

  candidate="${IMAGE_OUTPUT_DIR}/${manifest_build_log}"
  if [ -f "${candidate}" ]; then
    printf '%s\n' "${candidate}"
    return 0
  fi

  die "Missing image build log from manifest: ${candidate}"
}

function rootfs_build_log_for_manifest() {
  local manifest_rootfs_build_log="${1}"
  local rootfs_artifact="${2}"
  local candidate=''
  local expected_build_log=''

  [ -n "${rootfs_artifact}" ] || die "Manifest ${CURRENT_MANIFEST_PATH} is missing required field: rootfs_artifact"
  [ -n "${manifest_rootfs_build_log}" ] || die "Manifest ${CURRENT_MANIFEST_PATH} is missing required field: rootfs_build_log"
  expected_build_log="${rootfs_artifact%.tar.zst}.build.log"
  [ "${manifest_rootfs_build_log}" = "${expected_build_log}" ] || die "Manifest ${CURRENT_MANIFEST_PATH} has rootfs_build_log=${manifest_rootfs_build_log}, expected ${expected_build_log}"

  candidate="${ROOTFS_OUTPUT_DIR}/${manifest_rootfs_build_log}"
  if [ -f "${candidate}" ]; then
    printf '%s\n' "${candidate}"
    return 0
  fi

  die "Missing rootfs build log from manifest: ${candidate}"
}

function remember_immutable_upload() {
  local src="${1}"
  local key="${2}"
  local i=0

  for i in "${!IMMUTABLE_KEYS[@]}"; do
    if [ "${IMMUTABLE_KEYS[$i]}" = "${key}" ]; then
      [ "${IMMUTABLE_FILES[$i]}" = "${src}" ] || die "Immutable upload key has multiple sources: ${key}"
      return 0
    fi
  done

  IMMUTABLE_FILES+=("${src}")
  IMMUTABLE_KEYS+=("${key}")
}

function remember_build_identity() {
  local release_version="${1}"
  local artifact_version="${2}"

  if [ -z "${BUILD_RELEASE_VERSION}" ]; then
    BUILD_RELEASE_VERSION="${release_version}"
    BUILD_ARTIFACT_VERSION="${artifact_version}"
    return 0
  fi

  [ "${BUILD_RELEASE_VERSION}" = "${release_version}" ] || die 'Image manifests disagree on release_version'
  [ "${BUILD_ARTIFACT_VERSION}" = "${artifact_version}" ] || die 'Image manifests disagree on artifact_version'
}

function append_image_json() {
  local profile="${1}"
  local arch="${2}"
  local artifact_format="${3}"
  local filesystem="${4}"
  local boot_mode="${5}"
  local image_key="${6}"
  local sha256_key="${7}"
  local manifest_key="${8}"
  local build_log_key="${9}"
  local rootfs_build_log_key="${10}"

  jq -n \
    --arg profile "${profile}" \
    --arg arch "${arch}" \
    --arg format "${artifact_format}" \
    --arg filesystem "${filesystem}" \
    --arg boot_mode "${boot_mode}" \
    --arg url "$(r2_public_url_for_key "${image_key}")" \
    --arg sha256_url "$(r2_public_url_for_key "${sha256_key}")" \
    --arg manifest_url "$(r2_public_url_for_key "${manifest_key}")" \
    --arg build_log_url "$(r2_public_url_for_key "${build_log_key}")" \
    --arg rootfs_build_log_url "$(r2_public_url_for_key "${rootfs_build_log_key}")" \
    '{
      profile: $profile,
      arch: $arch,
      format: $format,
      filesystem: $filesystem,
      boot_mode: $boot_mode,
      url: $url,
      sha256_url: $sha256_url,
      manifest_url: $manifest_url,
      build_log_url: $build_log_url,
      rootfs_build_log_url: $rootfs_build_log_url
    }' >>"${IMAGES_JSONL}"
}

function process_manifest() {
  local manifest_path="${1}"
  local base_prefix="${2}"
  local artifact_type=''
  local artifact_name=''
  local artifact_format=''
  local release_version=''
  local build_id=''
  local artifact_version=''
  local profile=''
  local filesystem=''
  local boot_mode=''
  local built_at_utc=''
  local rootfs_artifact=''
  local rootfs_build_log=''
  local image_build_log=''
  local arch=''
  local image_path=''
  local sha256_path=''
  local build_log_path=''
  local rootfs_build_log_path=''
  local image_prefix=''
  local image_key=''
  local sha256_key=''
  local manifest_key=''
  local build_log_key=''
  local rootfs_build_log_key=''
  local checksum=''

  CURRENT_MANIFEST_PATH="${manifest_path}"

  # shellcheck disable=SC1090
  source "${manifest_path}"

  if [ "${artifact_type:-}" != "image" ]; then
    return 0
  fi

  require_manifest_field artifact_name
  require_manifest_field artifact_format
  require_manifest_field release_version
  require_manifest_field build_id
  require_manifest_field artifact_version
  require_manifest_field rootfs_artifact
  require_manifest_field rootfs_build_log
  require_manifest_field image_build_log
  require_manifest_field profile
  require_manifest_field filesystem
  require_manifest_field boot_mode
  [ -n "${built_at_utc}" ] || die "Manifest ${CURRENT_MANIFEST_PATH} is missing required field: built_at_utc"

  [ "${build_id}" = "${BUILD_ID}" ] || die "Manifest build_id=${build_id} does not match requested ${BUILD_ID}: ${manifest_path}"

  remember_build_identity "${release_version}" "${artifact_version}"

  arch="$(infer_arch "${artifact_name}")"
  image_path="${IMAGE_OUTPUT_DIR}/${artifact_name}"
  sha256_path="${image_path}.SHA256"
  build_log_path="$(build_log_for_manifest "${image_build_log}" "${artifact_name}" "${artifact_format}")"
  rootfs_build_log_path="$(rootfs_build_log_for_manifest "${rootfs_build_log}" "${rootfs_artifact}")"

  require_file "${image_path}" 'image artifact'
  require_file "${sha256_path}" 'image checksum'
  require_file "${manifest_path}" 'image manifest'
  require_file "${build_log_path}" 'image build log'
  require_file "${rootfs_build_log_path}" 'rootfs build log'

  verify_artifact_checksum "${sha256_path}"
  checksum="$(checksum_from_sha256_file "${sha256_path}")"

  image_prefix="${base_prefix}/${arch}/${profile}"
  image_key="${image_prefix}/${artifact_name}"
  sha256_key="${image_prefix}/${artifact_name}.SHA256"
  manifest_key="${image_prefix}/$(basename "${manifest_path}")"
  build_log_key="${image_prefix}/$(basename "${build_log_path}")"
  rootfs_build_log_key="${base_prefix}/rootfs/$(basename "${rootfs_build_log_path}")"

  printf '%s  %s/%s/%s\n' "${checksum}" "${arch}" "${profile}" "${artifact_name}" >>"${SHA256SUMS_PATH}"
  append_image_json "${profile}" "${arch}" "${artifact_format}" "${filesystem}" "${boot_mode}" \
    "${image_key}" "${sha256_key}" "${manifest_key}" "${build_log_key}" "${rootfs_build_log_key}"

  remember_immutable_upload "${image_path}" "${image_key}"
  remember_immutable_upload "${sha256_path}" "${sha256_key}"
  remember_immutable_upload "${manifest_path}" "${manifest_key}"
  remember_immutable_upload "${build_log_path}" "${build_log_key}"
  remember_immutable_upload "${rootfs_build_log_path}" "${rootfs_build_log_key}"

  log "Selected image manifest: $(basename "${manifest_path}") (${profile}, ${arch}, ${artifact_format})"
}

function discover_and_validate_manifests() {
  local base_prefix="${1}"
  local -a manifests=()
  local manifest=''

  shopt -s nullglob
  manifests=("${IMAGE_OUTPUT_DIR}"/*+"${BUILD_ID}".manifest)
  shopt -u nullglob

  [ "${#manifests[@]}" -gt 0 ] || die "No final image manifests found for build ${BUILD_ID} under ${IMAGE_OUTPUT_DIR}"

  for manifest in "${manifests[@]}"; do
    process_manifest "${manifest}" "${base_prefix}"
  done

  [ "${#IMMUTABLE_FILES[@]}" -gt 0 ] || die "No image artifacts selected for build ${BUILD_ID}"
}

function sign_sha256sums() {
  local -a gpg_cmd=(gpg --batch --yes --armor --detach-sign --output "${SHA256SUMS_ASC_PATH}")

  if [ "${NO_SIGN}" -eq 1 ]; then
    return 0
  fi

  if [ "${DRY_RUN}" -eq 1 ]; then
    log "DRY-RUN: would sign SHA256SUMS"
    : >"${SHA256SUMS_ASC_PATH}"
    return 0
  fi

  need_cmd gpg

  if [ -n "${GPG_SIGNING_KEY:-}" ]; then
    gpg_cmd+=(--local-user "${GPG_SIGNING_KEY}")
  fi

  gpg_cmd+=("${SHA256SUMS_PATH}")
  "${gpg_cmd[@]}" || die 'Failed to sign SHA256SUMS'
}

function generate_build_index() {
  local base_prefix="${1}"
  local checksums_key="${base_prefix}/SHA256SUMS"
  local checksums_signature_key="${base_prefix}/SHA256SUMS.asc"
  local signing_enabled='false'

  if [ "${NO_SIGN}" -eq 0 ]; then
    signing_enabled='true'
  fi

  jq -s \
    --arg schema 'ph20.blackarch.images.v1' \
    --arg project 'blackarch-cloud-images' \
    --arg channel "${CHANNEL}" \
    --arg build_id "${BUILD_ID}" \
    --arg release_version "${BUILD_RELEASE_VERSION}" \
    --arg artifact_version "${BUILD_ARTIFACT_VERSION}" \
    --arg published_at_utc "${PUBLISHED_AT_UTC}" \
    --arg public_key_url 'https://ph20.org/keys/packages.asc' \
    --arg checksums_url "$(r2_public_url_for_key "${checksums_key}")" \
    --arg checksums_signature_url "$(r2_public_url_for_key "${checksums_signature_key}")" \
    --argjson signing_enabled "${signing_enabled}" \
    '{
      schema: $schema,
      project: $project,
      channel: $channel,
      build_id: $build_id,
      release_version: $release_version,
      artifact_version: $artifact_version,
      published_at_utc: $published_at_utc,
      public_key_url: $public_key_url,
      checksums_url: $checksums_url,
      checksums_signature_url: (if $signing_enabled then $checksums_signature_url else null end),
      images: .
    }' "${IMAGES_JSONL}" >"${BUILD_INDEX_PATH}"
}

function initialize_root_index() {
  local latest_key="${1}"

  jq -n \
    --arg schema 'ph20.blackarch.images.index.v1' \
    --arg project 'blackarch-cloud-images' \
    --arg updated_at_utc "${PUBLISHED_AT_UTC}" \
    --arg channel "${CHANNEL}" \
    --arg latest_url "$(r2_public_url_for_key "${latest_key}")" \
    '{
      schema: $schema,
      project: $project,
      updated_at_utc: $updated_at_utc,
      channels: {($channel): {latest: $latest_url}},
      builds: []
    }' >"${EXISTING_ROOT_INDEX_PATH}"
}

function generate_root_index() {
  local build_index_key="${1}"
  local latest_key="${2}"
  local build_entry_path="${TMP_DIR}/build-entry.json"

  if [ "${DRY_RUN}" -eq 0 ] && r2_get_object_to_file 'blackarch/images/index.json' "${EXISTING_ROOT_INDEX_PATH}"; then
    jq empty "${EXISTING_ROOT_INDEX_PATH}" >/dev/null || die 'Existing root index JSON is invalid'
  else
    if [ "${DRY_RUN}" -eq 0 ]; then
      warn 'No existing blackarch/images/index.json found in R2; initializing a new root index'
    fi
    initialize_root_index "${latest_key}"
  fi

  jq -n \
    --arg channel "${CHANNEL}" \
    --arg build_id "${BUILD_ID}" \
    --arg artifact_version "${BUILD_ARTIFACT_VERSION}" \
    --arg index_url "$(r2_public_url_for_key "${build_index_key}")" \
    '{
      channel: $channel,
      build_id: $build_id,
      artifact_version: $artifact_version,
      index_url: $index_url
    }' >"${build_entry_path}"

  jq \
    --arg schema 'ph20.blackarch.images.index.v1' \
    --arg project 'blackarch-cloud-images' \
    --arg updated_at_utc "${PUBLISHED_AT_UTC}" \
    --arg channel "${CHANNEL}" \
    --arg latest_url "$(r2_public_url_for_key "${latest_key}")" \
    --slurpfile current_build "${build_entry_path}" \
    '
      .schema = $schema
      | .project = $project
      | .updated_at_utc = $updated_at_utc
      | .channels = (.channels // {})
      | .channels[$channel] = ((.channels[$channel] // {}) + {latest: $latest_url})
      | .builds = (
          (.builds // [])
          | map(select(.channel != $current_build[0].channel or .build_id != $current_build[0].build_id))
          + [$current_build[0]]
          | sort_by((.build_id | split(".")[0]), (.build_id | split(".")[1] | tonumber))
          | reverse
        )
    ' "${EXISTING_ROOT_INDEX_PATH}" >"${ROOT_INDEX_PATH}"
}

function remember_metadata_uploads() {
  local base_prefix="${1}"
  local build_index_key="${base_prefix}/index.json"
  local root_index_key='blackarch/images/index.json'
  local latest_key='blackarch/images/latest.json'

  METADATA_FILES+=("${BUILD_INDEX_PATH}")
  METADATA_KEYS+=("${build_index_key}")
  METADATA_IMMUTABLE+=("1")

  METADATA_FILES+=("${ROOT_INDEX_PATH}")
  METADATA_KEYS+=("${root_index_key}")
  METADATA_IMMUTABLE+=("0")

  if [ "${PROMOTE_LATEST}" -eq 1 ]; then
    METADATA_FILES+=("${BUILD_INDEX_PATH}")
    METADATA_KEYS+=("${latest_key}")
    METADATA_IMMUTABLE+=("0")
  fi
}

function print_plan_line() {
  local src="${1}"
  local key="${2}"
  local content_type=''
  local cache_control=''

  content_type="$(content_type_for_path "${key}")"
  cache_control="$(cache_control_for_key_or_path "${key}")"

  printf 'DRY-RUN upload: %s\n' "${key}"
  printf '  source: %s\n' "${src}"
  printf '  content-type: %s\n' "${content_type}"
  printf '  cache-control: %s\n' "${cache_control}"
  printf '  url: %s\n' "$(r2_public_url_for_key "${key}")"
}

function ensure_immutable_keys_available() {
  local key=''
  local i=0

  if [ "${DRY_RUN}" -eq 1 ] || [ "${ALLOW_OVERWRITE}" -eq 1 ]; then
    return 0
  fi

  for key in "${IMMUTABLE_KEYS[@]}"; do
    if r2_head_object "${key}"; then
      die "Refusing to overwrite existing immutable object without --allow-overwrite: ${key}"
    fi
  done

  for i in "${!METADATA_KEYS[@]}"; do
    if [ "${METADATA_IMMUTABLE[$i]}" = "1" ] && r2_head_object "${METADATA_KEYS[$i]}"; then
      die "Refusing to overwrite existing build metadata without --allow-overwrite: ${METADATA_KEYS[$i]}"
    fi
  done
}

function upload_or_print_file() {
  local src="${1}"
  local key="${2}"

  if [ "${DRY_RUN}" -eq 1 ]; then
    print_plan_line "${src}" "${key}"
    return 0
  fi

  r2_cp_file "${src}" "${key}" \
    "$(content_type_for_path "${key}")" \
    "$(cache_control_for_key_or_path "${key}")"
}

function upload_all() {
  local i=0

  ensure_immutable_keys_available

  for i in "${!IMMUTABLE_FILES[@]}"; do
    upload_or_print_file "${IMMUTABLE_FILES[$i]}" "${IMMUTABLE_KEYS[$i]}"
  done

  for i in "${!METADATA_FILES[@]}"; do
    upload_or_print_file "${METADATA_FILES[$i]}" "${METADATA_KEYS[$i]}"
  done
}

function main() {
  local year=''
  local base_prefix=''
  local checksums_key=''
  local checksums_signature_key=''
  local build_index_key=''
  local latest_key='blackarch/images/latest.json'

  parse_args "$@"

  [ -n "${BUILD_ID}" ] || die '--build-id is required'
  validate_build_id "${BUILD_ID}" || die "Invalid build ID: ${BUILD_ID}"
  validate_channel "${CHANNEL}" || die "Invalid channel: ${CHANNEL}"

  export R2_DRY_RUN="${DRY_RUN}"
  need_cmd jq
  need_cmd sha256sum
  r2_require_config
  r2_require_publish_tools

  TMP_DIR="$(mktemp -d)"
  SHA256SUMS_PATH="${TMP_DIR}/SHA256SUMS"
  SHA256SUMS_ASC_PATH="${TMP_DIR}/SHA256SUMS.asc"
  IMAGES_JSONL="${TMP_DIR}/images.jsonl"
  BUILD_INDEX_PATH="${TMP_DIR}/index.json"
  ROOT_INDEX_PATH="${TMP_DIR}/root-index.json"
  EXISTING_ROOT_INDEX_PATH="${TMP_DIR}/existing-root-index.json"
  PUBLISHED_AT_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  : >"${SHA256SUMS_PATH}"
  : >"${IMAGES_JSONL}"

  year="${BUILD_ID:0:4}"
  base_prefix="blackarch/images/${CHANNEL}/${year}/${BUILD_ID}"
  checksums_key="${base_prefix}/SHA256SUMS"
  checksums_signature_key="${base_prefix}/SHA256SUMS.asc"
  build_index_key="${base_prefix}/index.json"

  discover_and_validate_manifests "${base_prefix}"
  sign_sha256sums

  IMMUTABLE_FILES+=("${SHA256SUMS_PATH}")
  IMMUTABLE_KEYS+=("${checksums_key}")

  if [ "${NO_SIGN}" -eq 0 ]; then
    IMMUTABLE_FILES+=("${SHA256SUMS_ASC_PATH}")
    IMMUTABLE_KEYS+=("${checksums_signature_key}")
  fi

  generate_build_index "${base_prefix}"
  generate_root_index "${build_index_key}" "${latest_key}"
  remember_metadata_uploads "${base_prefix}"
  upload_all

  if [ "${DRY_RUN}" -eq 1 ]; then
    log 'DRY-RUN complete: no R2 uploads were performed.'
  else
    log "Published build ${BUILD_ID} to $(r2_public_url_for_key "${build_index_key}")"
  fi
}

main "$@"
