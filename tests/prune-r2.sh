#!/usr/bin/env bash

set -o nounset
set -o errexit
set -o pipefail

TEST_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP="$(mktemp -d)"
function cleanup() {
  local status=$?
  if [ "${status}" -ne 0 ] && [ -f "${TEST_CASE:-}/output" ]; then
    cat "${TEST_CASE}/output" >&2
  fi
  rm -rf "${TEST_TMP}"
}
trap cleanup EXIT
mkdir -p "${TEST_TMP}/bin" "${TEST_TMP}/fixture"
cp "${TEST_REPO}/tests/helpers/prune-r2-aws.sh" "${TEST_TMP}/bin/aws"
chmod +x "${TEST_TMP}/bin/aws"

jq -n '
  "https://artifacts.invalid/blackarch/images" as $base
  | {schema: "ph20.blackarch.images.index.v1", project: "blackarch-cloud-images",
     extra_field: "preserved", channels: {weekly: {latest: ($base + "/latest.json")},
     releases: {latest: ($base + "/latest.json")}},
     builds: (["20261024.0", "20261023.11", "20261023.10", "20261023.9",
       "20261023.2", "20261023.1", "20261023.0", "20261001.0"]
       | map({channel: "weekly", build_id: ., index_url: ($base + "/weekly/2026/" + . + "/index.json")}))}
  | .builds += [{channel: "releases", build_id: "20260101.0", index_url: ($base + "/releases/2026/20260101.0/index.json")}]
' >"${TEST_TMP}/fixture/index.json"

jq -n '
  "https://artifacts.invalid/blackarch/images/weekly/2026/20261001.0/" as $prefix
  | {schema: "ph20.blackarch.images.v1", project: "blackarch-cloud-images",
     channel: "weekly", build_id: "20261001.0", checksums_url: ($prefix + "SHA256SUMS"),
     checksums_signature_url: ($prefix + "SHA256SUMS.asc"),
     images: [{url: ($prefix + "image.qcow2"), sha256_url: ($prefix + "image.SHA256"),
       manifest_url: ($prefix + "image.manifest"), build_log_url: ($prefix + "image.build.log"),
       rootfs_build_log_url: ($prefix + "rootfs/rootfs.build.log")} ]}
' >"${TEST_TMP}/fixture/latest.json"

jq '[.builds[] | ("blackarch/images/" + .channel + "/2026/" + .build_id + "/") as $prefix
    | {Key: ($prefix + "index.json"), Size: 100}, {Key: ($prefix + "logs/build log.build.log"), Size: 20},
      (if .build_id == "20261023.2" then range(0; 1001) else 0 end
       | {Key: ($prefix + "image-" + tostring + ".qcow2"), Size: 1048576})]
    + [{Key: "blackarch/images/weekly/2026/20261005.0/unindexed.qcow2", Size: 1}]
' "${TEST_TMP}/fixture/index.json" >"${TEST_TMP}/fixture/objects.json"

function setup_case() {
  TEST_CASE="${TEST_TMP}/${1}"
  mkdir -p "${TEST_CASE}"
  cp "${TEST_TMP}/fixture/"*.json "${TEST_CASE}/"
  : >"${TEST_CASE}/calls"
}

function run_prune() {
  local scenario="${1}"
  shift
  PATH="${TEST_TMP}/bin:${PATH}" TEST_CASE="${TEST_CASE}" TEST_SCENARIO="${scenario}" \
    R2_BUCKET=test R2_ENDPOINT_URL=https://r2.invalid R2_PUBLIC_BASE_URL=https://artifacts.invalid \
    AWS_PROFILE='' AWS_CLI_EXTRA_ARGS='' \
    "${TEST_REPO}/scripts/prune-r2.sh" "$@" >"${TEST_CASE}/output" 2>&1
}

function assert_no_mutations() {
  if grep -Eq '^(delete-objects|put-object) ' "${TEST_CASE}/calls"; then
    cat "${TEST_CASE}/output" >&2
    printf '%s\n' 'Unexpected R2 mutation' >&2
    exit 1
  fi
}

setup_case default
run_prune normal
assert_no_mutations
cmp "${TEST_TMP}/fixture/index.json" "${TEST_CASE}/index.json"
cmp "${TEST_TMP}/fixture/objects.json" "${TEST_CASE}/objects.json"
grep -q '^KEEP weekly/20261023.9$' "${TEST_CASE}/output"
grep -q '^KEEP weekly/20261001.0$' "${TEST_CASE}/output"
[ "$(grep -c '^PRUNE ' "${TEST_CASE}/output")" -eq 3 ]
[ "$(grep -c '^list-objects-v2 .*20261023.2/' "${TEST_CASE}/calls")" -eq 2 ]

setup_case apply
run_prune normal --apply
[ "$(grep -c '^delete-objects ' "${TEST_CASE}/calls")" -eq 4 ]
[ "$(grep -c '^put-object ' "${TEST_CASE}/calls")" -eq 3 ]
jq -e '.extra_field == "preserved" and (.builds | length == 6)
  and any(.builds[]; .channel == "releases")
  and any(.builds[]; .build_id == "20261001.0")
  and all(.builds[]; .build_id != "20261023.2" and .build_id != "20261023.1" and .build_id != "20261023.0")
' "${TEST_CASE}/index.json" >/dev/null
jq -e 'length == 19 and any(.[]; .Key | contains("unindexed.qcow2"))
  and any(.[]; .Key | contains("/releases/"))' "${TEST_CASE}/objects.json" >/dev/null
cmp "${TEST_TMP}/fixture/latest.json" "${TEST_CASE}/latest.json"
run_prune normal --apply
grep -q 'Nothing to prune.' "${TEST_CASE}/output"

setup_case keep-all
run_prune normal --keep-last 8 --apply
assert_no_mutations

setup_case latest-release
jq 'walk(if type == "string" then gsub("weekly/2026/20261001.0/"; "releases/2026/20260101.0/") else . end)
  | .channel = "releases" | .build_id = "20260101.0"' "${TEST_CASE}/latest.json" >"${TEST_CASE}/release-latest.json"
mv "${TEST_CASE}/release-latest.json" "${TEST_CASE}/latest.json"
run_prune normal --apply
jq -e '.builds | length == 5' "${TEST_CASE}/index.json" >/dev/null

setup_case custom-count
run_prune normal --keep-last 2 --dry-run
assert_no_mutations
[ "$(grep -c '^PRUNE ' "${TEST_CASE}/output")" -eq 5 ]

for failure in old-cli get-error list-error outside-prefix repeated-token race-index race-latest; do
  setup_case "${failure}"
  if run_prune "${failure}" --apply; then
    printf 'Expected failure: %s\n' "${failure}" >&2
    exit 1
  fi
  assert_no_mutations
done

for invalid in root-schema latest-schema latest-id latest-url root-url duplicate; do
  setup_case "${invalid}"
  target=index
  case "${invalid}" in
    root-schema) filter='.schema = "other"' ;;
    latest-schema) target=latest; filter='.schema = "other"' ;;
    latest-id) target=latest; filter='.build_id = "20260901.0"' ;;
    latest-url) target=latest; filter='.images[0].url = "https://artifacts.invalid/blackarch/images/weekly/2026/20261023.0/image.qcow2"' ;;
    root-url) filter='.builds[0].index_url = "https://other.invalid/index.json"' ;;
    duplicate) filter='.builds += [.builds[0]]' ;;
  esac
  jq "${filter}" "${TEST_CASE}/${target}.json" >"${TEST_CASE}/invalid.json"
  mv "${TEST_CASE}/invalid.json" "${TEST_CASE}/${target}.json"
  if run_prune normal --apply; then
    printf 'Expected metadata failure: %s\n' "${invalid}" >&2
    exit 1
  fi
  assert_no_mutations
done

setup_case delete-error
if run_prune delete-error --apply; then exit 1; fi
cmp "${TEST_TMP}/fixture/index.json" "${TEST_CASE}/index.json"
run_prune normal --apply
jq -e '.builds | length == 6' "${TEST_CASE}/index.json" >/dev/null

setup_case delete-command-error
if run_prune delete-command-error --apply; then exit 1; fi
cmp "${TEST_TMP}/fixture/index.json" "${TEST_CASE}/index.json"

for format in delete-json-success delete-whitespace-success; do
  setup_case "${format}"
  run_prune "${format}" --apply
  jq -e '.builds | length == 6' "${TEST_CASE}/index.json" >/dev/null
done

for invalid_response in delete-malformed delete-invalid-errors; do
  setup_case "${invalid_response}"
  if run_prune "${invalid_response}" --apply; then exit 1; fi
  cmp "${TEST_TMP}/fixture/index.json" "${TEST_CASE}/index.json"
done

# Recover when the previous quiet deletion succeeded but the catalog was kept.
setup_case already-deleted
jq 'map(select(.Key | startswith("blackarch/images/weekly/2026/20261023.2/") | not))' \
  "${TEST_CASE}/objects.json" >"${TEST_CASE}/remaining.json"
mv "${TEST_CASE}/remaining.json" "${TEST_CASE}/objects.json"
run_prune normal --apply
[ "$(grep -c '^delete-objects ' "${TEST_CASE}/calls")" -eq 2 ]
[ "$(grep -c '^put-object ' "${TEST_CASE}/calls")" -eq 3 ]
jq -e '.builds | length == 6' "${TEST_CASE}/index.json" >/dev/null

setup_case put-race
if run_prune put-race --apply; then exit 1; fi
jq -e '.concurrent_publish == true and any(.builds[]; .build_id == "20261023.2")' "${TEST_CASE}/index.json" >/dev/null
run_prune normal --apply
jq -e '.concurrent_publish == true and (.builds | length == 6)' "${TEST_CASE}/index.json" >/dev/null

setup_case args
if run_prune normal --channel releases --apply; then exit 1; fi
if run_prune normal --keep-last 0 --apply; then exit 1; fi
if run_prune normal --dry-run --apply; then exit 1; fi
[ ! -s "${TEST_CASE}/calls" ]
printf '%s\n' 'R2 pruning checks passed (offline; no real R2 access).'
