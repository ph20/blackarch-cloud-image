#!/usr/bin/env bash

set -o nounset
set -o errexit
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

# shellcheck source=scripts/lib/r2.sh
source "${SCRIPT_DIR}/lib/r2.sh"

KEEP_LAST=4
APPLY=0
MODE=''
TMP_DIR=''
ROOT_INDEX_KEY='blackarch/images/index.json'
LATEST_KEY='blackarch/images/latest.json'
ROOT_INDEX_ETAG=''
LATEST_ETAG=''

function usage() {
  cat <<'EOF'
Usage: scripts/prune-r2.sh [options]

Plan removal of old published weekly builds from R2 (dry-run by default).
Keep the newest 4 builds and always protect the build referenced by latest.json.
Release builds and unindexed objects are never selected.

Options:
  --keep-last N       Keep the newest N weekly builds (positive integer; default: 4)
  --channel weekly    Only the weekly channel can be pruned
  --dry-run           Read R2 and print exact object keys without changing R2
  --apply             Delete selected objects and update the root index
  -h, --help          Show this help

Requires the same R2 configuration and credentials as publish-r2.sh, including
for dry runs. Run only while publishing and other pruning processes are idle.
EOF
}

function die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

function cleanup() {
  if [ -n "${TMP_DIR}" ]; then
    rm -rf "${TMP_DIR}"
  fi
}
trap cleanup EXIT

function parse_args() {
  local next_mode=''

  while [ "$#" -gt 0 ]; do
    case "${1}" in
      --keep-last)
        [ "$#" -ge 2 ] || die '--keep-last requires a value'
        KEEP_LAST="${2}"
        shift
        ;;
      --channel)
        [ "$#" -ge 2 ] || die '--channel requires a value'
        [ "${2}" = weekly ] || die 'Only the weekly channel can be pruned'
        shift
        ;;
      --dry-run | --apply)
        next_mode="${1}"
        [ -z "${MODE}" ] || [ "${MODE}" = "${next_mode}" ] || die '--dry-run and --apply cannot be combined'
        MODE="${next_mode}"
        if [ "${MODE}" = --apply ]; then APPLY=1; fi
        ;;
      -h | --help)
        usage
        exit 0
        ;;
      *) die "Unknown option: ${1}" ;;
    esac
    shift
  done

  [[ "${KEEP_LAST}" =~ ^[1-9][0-9]{0,8}$ ]] || die '--keep-last must be a positive integer of at most 9 digits'
}

function get_metadata() {
  local key="${1}"
  local destination="${2}"

  "${R2_AWS_CMD[@]}" s3api get-object --bucket "${R2_BUCKET}" --key "${key}" \
    "${destination}" --output json >"${destination}.response" || return 1
  jq -er '.ETag | select(type == "string" and length > 0)' "${destination}.response"
}

function validate_metadata() {
  local base="${R2_PUBLIC_BASE_URL%/}/blackarch/images"

  jq -e --arg base "${base}" '
    .schema == "ph20.blackarch.images.index.v1" and .project == "blackarch-cloud-images"
    and (.channels | type == "object") and (.builds | type == "array")
    and all(.channels[]; .latest == ($base + "/latest.json"))
    and all(.builds[];
      (.channel == "weekly" or .channel == "releases")
      and (.build_id | type == "string" and test("^[0-9]{8}\\.[0-9]+$"))
      and .index_url == ($base + "/" + .channel + "/" + .build_id[0:4] + "/" + .build_id + "/index.json"))
    and ([.builds[] | [.channel, .build_id]] | length == (unique | length))
  ' "${TMP_DIR}/index.json" >/dev/null || die 'Invalid root index or unrecognized index/latest URLs; refusing to prune'

  jq -e --slurpfile index "${TMP_DIR}/index.json" --arg base "${base}" '
    . as $latest
    | .schema == "ph20.blackarch.images.v1" and .project == "blackarch-cloud-images"
      and (.channel == "weekly" or .channel == "releases")
      and (.build_id | type == "string" and test("^[0-9]{8}\\.[0-9]+$"))
      and any($index[0].builds[]; .channel == $latest.channel and .build_id == $latest.build_id)
      and (.images | type == "array" and length > 0)
      and (($base + "/" + .channel + "/" + .build_id[0:4] + "/" + .build_id + "/") as $prefix
        | .checksums_url == ($prefix + "SHA256SUMS")
          and ((.checksums_signature_url == null) or .checksums_signature_url == ($prefix + "SHA256SUMS.asc"))
          and all(.images[]; all(.url, .sha256_url, .manifest_url, .build_log_url, .rootfs_build_log_url;
            type == "string" and startswith($prefix))))
  ' "${TMP_DIR}/latest.json" >/dev/null || die 'Invalid latest.json or latest build absent from root index; refusing to prune'
}

function select_builds() {
  jq --argjson keep "${KEEP_LAST}" --slurpfile latest "${TMP_DIR}/latest.json" '
    [.builds[] | select(.channel == "weekly")]
    | sort_by((.build_id | split(".")[0]), (.build_id | split(".")[1] | tonumber)) | reverse
    | to_entries | map(. + {protected: (.key < $keep or
        ($latest[0].channel == "weekly" and .value.build_id == $latest[0].build_id))})
  ' "${TMP_DIR}/index.json" >"${TMP_DIR}/selection.json"

  jq -r '.[] | select(.protected) | "KEEP weekly/" + .value.build_id' "${TMP_DIR}/selection.json"
  jq -r '.[] | select(.protected | not) | .value.build_id' "${TMP_DIR}/selection.json" >"${TMP_DIR}/candidates"
}

function list_build_objects() {
  local build_id="${1}"
  local prefix="blackarch/images/weekly/${build_id:0:4}/${build_id}/"
  local token=''
  local next_token=''
  local -a pagination=()

  : >"${TMP_DIR}/objects.jsonl"
  : >"${TMP_DIR}/tokens"
  while :; do
    "${R2_AWS_CMD[@]}" s3api list-objects-v2 --bucket "${R2_BUCKET}" --prefix "${prefix}" \
      --no-paginate "${pagination[@]}" --output json >"${TMP_DIR}/page.json"
    jq -e --arg prefix "${prefix}" '
      type == "object" and ((.Contents // []) | type == "array")
      and ((.IsTruncated // false) | type == "boolean")
      and all((.Contents // [])[];
        (.Key | type == "string" and startswith($prefix) and length > ($prefix | length)
          and (test("[[:cntrl:]]") | not))
        and (.Size | type == "number" and . >= 0 and floor == .))
    ' "${TMP_DIR}/page.json" >/dev/null || die "Invalid object listing for ${prefix}"
    jq -c '(.Contents // [])[] | {Key, Size}' "${TMP_DIR}/page.json" >>"${TMP_DIR}/objects.jsonl"
    if ! jq -e '.IsTruncated == true' "${TMP_DIR}/page.json" >/dev/null; then break; fi
    next_token="$(jq -er '.NextContinuationToken | select(type == "string" and length > 0)' "${TMP_DIR}/page.json")"
    if [ "${next_token}" = "${token}" ] || grep -Fxq -- "${next_token}" "${TMP_DIR}/tokens"; then
      die 'Repeated R2 pagination token'
    fi
    token="${next_token}"
    printf '%s\n' "${token}" >>"${TMP_DIR}/tokens"
    pagination=(--continuation-token "${token}")
  done

  jq -s --arg build_id "${build_id}" --arg prefix "${prefix}" '
    if (length != (unique_by(.Key) | length)) then error("Duplicate object keys in listing") else
      {build_id: $build_id, prefix: $prefix, objects: .}
    end
  ' "${TMP_DIR}/objects.jsonl" >"${TMP_DIR}/build-${build_id}.json"
}

function print_plan() {
  local build_id=''

  while IFS= read -r build_id; do
    list_build_objects "${build_id}"
    printf 'PRUNE weekly/%s\n' "${build_id}"
    jq -r '.objects[] | "  DELETE " + .Key' "${TMP_DIR}/build-${build_id}.json"
    jq -r '"  Objects: \(.objects | length); bytes: \([.objects[].Size] | add // 0)"' "${TMP_DIR}/build-${build_id}.json"
  done <"${TMP_DIR}/candidates"
}

function assert_metadata_unchanged() {
  local key=''
  local expected=''
  local actual=''

  for key in "${ROOT_INDEX_KEY}" "${LATEST_KEY}"; do
    expected="${ROOT_INDEX_ETAG}"
    if [ "${key}" = "${LATEST_KEY}" ]; then expected="${LATEST_ETAG}"; fi
    actual="$("${R2_AWS_CMD[@]}" s3api head-object --bucket "${R2_BUCKET}" --key "${key}" \
      --query ETag --output text)"
    [ "${actual}" = "${expected}" ] || die "${key} changed during pruning; stop concurrent publishing/pruning and rerun a dry-run"
  done
}

function prune_build() {
  local build_id="${1}"
  local count=0
  local offset=0
  local response=''

  assert_metadata_unchanged
  count="$(jq '.objects | length' "${TMP_DIR}/build-${build_id}.json")"
  for ((offset = 0; offset < count; offset += 1000)); do
    assert_metadata_unchanged
    jq --argjson start "${offset}" '{Objects: [.objects[$start:($start + 1000)][] | {Key}], Quiet: true}' \
      "${TMP_DIR}/build-${build_id}.json" >"${TMP_DIR}/delete.json"
    "${R2_AWS_CMD[@]}" s3api delete-objects --bucket "${R2_BUCKET}" \
      --delete "file://${TMP_DIR}/delete.json" --output json >"${TMP_DIR}/deleted.json"
    # Quiet DeleteObjects success can become empty stdout: AWS CLI omits {}.
    # The command must succeed; any nonempty response must be one valid JSON
    # object without per-object errors. Slurping also accepts whitespace only.
    jq -se 'length == 0 or (length == 1 and (.[0] | type == "object"
      and (.Errors == null or (.Errors | type == "array" and length == 0))))' \
      "${TMP_DIR}/deleted.json" >/dev/null || {
      cat "${TMP_DIR}/deleted.json" >&2
      die "Object deletion failed for ${build_id}; its root index entry is retained. Rerun a dry-run before retrying"
    }
  done

  assert_metadata_unchanged
  jq --arg id "${build_id}" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
    .builds |= map(select(.channel != "weekly" or .build_id != $id))
    | .updated_at_utc = $now
  ' "${TMP_DIR}/index.json" >"${TMP_DIR}/updated-index.json"
  response="$("${R2_AWS_CMD[@]}" s3api put-object --bucket "${R2_BUCKET}" --key "${ROOT_INDEX_KEY}" \
    --body "${TMP_DIR}/updated-index.json" --if-match "${ROOT_INDEX_ETAG}" \
    --content-type application/json --cache-control "$(cache_control_for_key_or_path "${ROOT_INDEX_KEY}")" --output json)" || \
    die "Could not update root index after deleting ${build_id}; rerun a dry-run to reconcile the remaining index entry"
  ROOT_INDEX_ETAG="$(jq -er '.ETag | select(type == "string" and length > 0)' <<<"${response}")"
  mv "${TMP_DIR}/updated-index.json" "${TMP_DIR}/index.json"
  printf 'Pruned weekly/%s and updated %s\n' "${build_id}" "${ROOT_INDEX_KEY}"
}

function main() {
  local command=''
  local build_id=''

  parse_args "$@"
  for command in aws jq grep; do
    command -v "${command}" >/dev/null 2>&1 || die "Missing required command: ${command}"
  done
  # Dry-run still reads the real R2 catalog and requires valid configuration.
  export R2_DRY_RUN=0 AWS_PAGER=''
  r2_require_config
  r2_aws_base_command
  TMP_DIR="$(mktemp -d)"
  if [ "${APPLY}" -eq 1 ]; then
    "${R2_AWS_CMD[@]}" s3api put-object --generate-cli-skeleton input >"${TMP_DIR}/put-skeleton.json"
    jq -e 'has("IfMatch")' "${TMP_DIR}/put-skeleton.json" >/dev/null || die 'AWS CLI must support put-object --if-match; no objects were deleted'
  fi
  ROOT_INDEX_ETAG="$(get_metadata "${ROOT_INDEX_KEY}" "${TMP_DIR}/index.json")"
  LATEST_ETAG="$(get_metadata "${LATEST_KEY}" "${TMP_DIR}/latest.json")"
  validate_metadata
  jq -r '"Protected latest: \(.channel)/\(.build_id)"' "${TMP_DIR}/latest.json"
  select_builds
  print_plan
  if [ ! -s "${TMP_DIR}/candidates" ]; then
    printf '%s\n' 'Nothing to prune.'
  elif [ "${APPLY}" -eq 0 ]; then
    printf 'DRY-RUN: would update %s; no R2 objects were changed. Use --apply to execute.\n' "${ROOT_INDEX_KEY}"
  else
    while IFS= read -r build_id; do prune_build "${build_id}"; done <"${TMP_DIR}/candidates"
  fi
}

main "$@"
