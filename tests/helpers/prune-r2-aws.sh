#!/usr/bin/env bash
# Local R2 emulator used only by tests/prune-r2.sh.
set -o nounset
set -o errexit
set -o pipefail

while [ "${1:-}" != s3api ]; do
  [ "$#" -gt 0 ] || exit 1
  shift
done
shift
operation="${1}"
shift
key=''
prefix=''
token=0
body=''
delete_file=''
if_match=''
destination=''
skeleton=0
while [ "$#" -gt 0 ]; do
  case "${1}" in
    --key) key="${2}"; shift ;;
    --prefix) prefix="${2}"; shift ;;
    --continuation-token) token="${2}"; shift ;;
    --body) body="${2}"; shift ;;
    --delete) delete_file="${2#file://}"; shift ;;
    --if-match) if_match="${2}"; shift ;;
    --generate-cli-skeleton) skeleton=1; shift ;;
    --bucket | --query | --output | --content-type | --cache-control) shift ;;
    --no-paginate) : ;;
    --*) exit 1 ;;
    *) destination="${1}" ;;
  esac
  shift
done
if [ "${skeleton}" -eq 1 ]; then
  if [ "${TEST_SCENARIO}" = old-cli ]; then printf '%s\n' '{}'; else printf '%s\n' '{"IfMatch":""}'; fi
  exit 0
fi
printf '%s %s%s\n' "${operation}" "${key}" "${prefix}" >>"${TEST_CASE}/calls"

function metadata_file() {
  case "${key}" in
    blackarch/images/index.json) printf '%s/index.json\n' "${TEST_CASE}" ;;
    blackarch/images/latest.json) printf '%s/latest.json\n' "${TEST_CASE}" ;;
    *) exit 1 ;;
  esac
}

function etag() {
  printf '"%s"\n' "$(sha256sum "${1}" | cut -d' ' -f1)"
}

case "${operation}" in
  get-object)
    [ "${TEST_SCENARIO}" != get-error ] || exit 1
    cp "$(metadata_file)" "${destination}"
    jq -n --arg etag "$(etag "${destination}")" '{ETag: $etag}'
    ;;
  head-object)
    if [ "${TEST_SCENARIO}" = race-index ] && [[ "${key}" = */index.json ]]; then
      jq '.concurrent_publish = true' "${TEST_CASE}/index.json" >"${TEST_CASE}/changed.json"
      mv "${TEST_CASE}/changed.json" "${TEST_CASE}/index.json"
    elif [ "${TEST_SCENARIO}" = race-latest ] && [[ "${key}" = */latest.json ]]; then
      jq '.concurrent_publish = true' "${TEST_CASE}/latest.json" >"${TEST_CASE}/changed.json"
      mv "${TEST_CASE}/changed.json" "${TEST_CASE}/latest.json"
    fi
    etag "$(metadata_file)"
    ;;
  list-objects-v2)
    [ "${TEST_SCENARIO}" != list-error ] || exit 1
    jq --arg prefix "${prefix}" --argjson offset "${token}" '
      map(select(.Key | startswith($prefix))) | sort_by(.Key) | . as $all
      | {Contents: .[$offset:($offset + 1000)], IsTruncated: (($offset + 1000) < length)}
      | if .IsTruncated then .NextContinuationToken = (($offset + 1000) | tostring) else . end
    ' "${TEST_CASE}/objects.json" >"${TEST_CASE}/page.json"
    case "${TEST_SCENARIO}" in
      outside-prefix)
        jq '.Contents += [{Key: "blackarch/images/releases/2026/20260101.0/image.qcow2", Size: 1}]' \
          "${TEST_CASE}/page.json" >"${TEST_CASE}/bad-page.json"
        mv "${TEST_CASE}/bad-page.json" "${TEST_CASE}/page.json"
        ;;
      repeated-token)
        jq '.IsTruncated = true | .NextContinuationToken = "0"' \
          "${TEST_CASE}/page.json" >"${TEST_CASE}/bad-page.json"
        mv "${TEST_CASE}/bad-page.json" "${TEST_CASE}/page.json"
        ;;
    esac
    cat "${TEST_CASE}/page.json"
    ;;
  delete-objects)
    [ "${TEST_SCENARIO}" != delete-command-error ] || exit 1
    jq -e '.Objects | length > 0 and length <= 1000' "${delete_file}" >/dev/null
    jq -e 'all(.Objects[]; .Key | startswith("blackarch/images/weekly/"))' "${delete_file}" >/dev/null
    cp "${delete_file}" "${TEST_CASE}/request.json"
    if [ "${TEST_SCENARIO}" = delete-error ]; then
      jq '.Objects |= .[0:-1]' "${delete_file}" >"${TEST_CASE}/request.json"
    fi
    jq --slurpfile request "${TEST_CASE}/request.json" '
      map(select(.Key as $key | all($request[0].Objects[]; .Key != $key)))
    ' "${TEST_CASE}/objects.json" >"${TEST_CASE}/remaining.json"
    mv "${TEST_CASE}/remaining.json" "${TEST_CASE}/objects.json"
    if [ "${TEST_SCENARIO}" = delete-error ]; then
      printf '%s\n' '{"Errors":[{"Key":"failed","Code":"AccessDenied"}]}'
    elif [ "${TEST_SCENARIO}" = delete-json-success ]; then
      printf '%s\n' '{}'
    elif [ "${TEST_SCENARIO}" = delete-whitespace-success ]; then
      printf ' \n\t\n'
    elif [ "${TEST_SCENARIO}" = delete-malformed ]; then
      printf '%s\n' 'not a JSON response'
    elif [ "${TEST_SCENARIO}" = delete-invalid-errors ]; then
      printf '%s\n' '{"Errors":false}'
    fi
    ;;
  put-object)
    [ "${key}" = blackarch/images/index.json ] || exit 1
    if [ "${TEST_SCENARIO}" = put-race ]; then
      jq '.concurrent_publish = true' "${TEST_CASE}/index.json" >"${TEST_CASE}/changed.json"
      mv "${TEST_CASE}/changed.json" "${TEST_CASE}/index.json"
    fi
    [ "${if_match}" = "$(etag "${TEST_CASE}/index.json")" ] || exit 1
    cp "${body}" "${TEST_CASE}/index.json"
    jq -n --arg etag "$(etag "${TEST_CASE}/index.json")" '{ETag: $etag}'
    ;;
  *) exit 1 ;;
esac
