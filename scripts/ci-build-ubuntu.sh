#!/usr/bin/env bash

set -o nounset
set -o errexit
set -o pipefail

CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly CHECKOUT_ROOT

if [ "${GITHUB_ACTIONS:-}" != true ] || [ "${RUNNER_OS:-}" != Linux ] || [ "$(uname -m)" != x86_64 ]; then
  printf '%s\n' 'This helper requires an x86_64 Linux GitHub Actions runner.' >&2
  exit 1
fi

BUILD_WORKSPACE="${BUILD_WORKSPACE:-${RUNNER_TEMP:?}/blackarch-build}"
BUILD_ID="${BUILD_ID:-$(date -u +%Y%m%d).${GITHUB_RUN_NUMBER:?}}"
CONTAINER_NAME="blackarch-build-${GITHUB_RUN_ID:?}-${GITHUB_RUN_ATTEMPT:?}"
readonly BUILD_WORKSPACE BUILD_ID CONTAINER_NAME

function collect_diagnostics() {
  local source=''
  local destination=''

  mkdir -p "${BUILD_WORKSPACE}/public"

  # Container checkout paths differ from the runner's checkout path. Reuse the
  # publishing sanitizer with the checkout location recorded by the container.
  local PROJECT_ROOT=/repo
  # shellcheck source=scripts/lib/public-log.sh
  source "${CHECKOUT_ROOT}/scripts/lib/public-log.sh"

  shopt -s nullglob
  for source in "${BUILD_WORKSPACE}"/container.build.log "${BUILD_WORKSPACE}"/output/{rootfs,images}/*.build.log; do
    [ -f "${source}" ] || continue
    destination="${BUILD_WORKSPACE}/public/$(basename "${source}")"
    sanitize_public_build_log "${source}" "${destination}" || return 1
  done
  for source in "${BUILD_WORKSPACE}"/output/{rootfs,images}/*.manifest "${BUILD_WORKSPACE}"/output/images/*.SHA256; do
    cp "${source}" "${BUILD_WORKSPACE}/public/" || return 1
  done
  shopt -u nullglob
}

function cleanup() {
  local exit_code=$?
  trap - EXIT
  docker rm --force "${CONTAINER_NAME}" >/dev/null 2>&1 || true
  if ! collect_diagnostics; then
    printf '%s\n' 'Failed to prepare public build diagnostics.' >&2
    exit_code=1
  fi
  df -h "${BUILD_WORKSPACE}" || true
  exit "${exit_code}"
}

mkdir -p "${BUILD_WORKSPACE}"
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# The container shares the Ubuntu kernel. Load filesystem and loop support on
# the host, and share /dev so partitions created after startup become visible.
sudo modprobe loop
sudo modprobe btrfs
sudo udevadm settle
df -h "${BUILD_WORKSPACE}"
docker pull archlinux:latest

docker run --rm --name "${CONTAINER_NAME}" --privileged \
  --mount type=bind,source=/dev,target=/dev \
  --mount type=bind,source=/run/udev,target=/run/udev,readonly \
  --mount "type=bind,source=${CHECKOUT_ROOT},target=/repo,readonly" \
  --mount "type=bind,source=${BUILD_WORKSPACE},target=/build" \
  --workdir /repo \
  --env GITHUB_ACTIONS=true \
  --env BUILD_WORKSPACE=/build \
  --env "BUILD_ID=${BUILD_ID}" \
  --env "IMAGE_PROFILE=${IMAGE_PROFILE:-generic-qemu}" \
  --env "DISK_SIZE=${DISK_SIZE:-4G}" \
  --env BLACKARCH_PROFILE=core \
  archlinux:latest bash /repo/scripts/ci-build-arch.sh \
  2>&1 | tee "${BUILD_WORKSPACE}/container.build.log"
