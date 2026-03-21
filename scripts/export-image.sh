#!/usr/bin/env bash

set -o nounset
set -o errexit
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=scripts/lib/config.sh
source "${SCRIPT_DIR}/lib/config.sh"
# shellcheck source=scripts/lib/logging.sh
source "${SCRIPT_DIR}/lib/logging.sh"
# shellcheck source=scripts/lib/manifest.sh
source "${SCRIPT_DIR}/lib/manifest.sh"

function export_qcow2() {
  qemu-img convert -c -f raw -O qcow2 "${STAGING_IMAGE_PATH}" "${FINAL_IMAGE_PATH}"
}

function export_raw_gz() {
  gzip -n -c "${STAGING_IMAGE_PATH}" >"${FINAL_IMAGE_PATH}"
}

function write_checksum() {
  (
    cd "${IMAGE_OUTPUT_DIR}"
    sha256sum "$(basename "${FINAL_IMAGE_PATH}")" >"$(basename "${FINAL_IMAGE_CHECKSUM_PATH}")"
  )
}

function main() {
  require_root
  resolve_build_context "${1:-${BUILD_VERSION:-}}"
  ensure_directories "${IMAGE_OUTPUT_DIR}"

  if [ ! -f "${STAGING_IMAGE_PATH}" ]; then
    printf 'Missing staging image: %s\n' "${STAGING_IMAGE_PATH}" >&2
    exit 1
  fi

  rm -f "${FINAL_IMAGE_PATH}" "${FINAL_IMAGE_CHECKSUM_PATH}" "${FINAL_IMAGE_MANIFEST_PATH}"

  log_step "Stage 3: exporting ${RESOLVED_IMAGE_PROFILE} artifact"
  case "${RESOLVED_IMAGE_FINAL_FORMAT}" in
    qcow2)
      export_qcow2
      ;;
    raw.gz | img.gz)
      export_raw_gz
      ;;
    *)
      printf 'Unsupported final image format: %s\n' "${RESOLVED_IMAGE_FINAL_FORMAT}" >&2
      exit 1
      ;;
  esac

  log_step "Stage 3: writing final artifact checksum"
  write_checksum

  log_step "Stage 3: writing final image manifest"
  write_final_image_manifest
  chown_to_invoking_user "${FINAL_IMAGE_PATH}" "${FINAL_IMAGE_CHECKSUM_PATH}" "${FINAL_IMAGE_MANIFEST_PATH}" 2>/dev/null || true
}

main "${1:-}"
