#!/usr/bin/env bash

set -o nounset
set -o errexit
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
readonly PROJECT_ROOT
IMAGE_NAME_PREFIX="BlackArch-Linux-x86_64-cloudimg"
readonly IMAGE_NAME_PREFIX
OUTPUT_ROOT="${PROJECT_ROOT}/output"
readonly OUTPUT_ROOT
TMP_ROOT="${PROJECT_ROOT}/tmp"
readonly TMP_ROOT

function mount_targets_under_tmp() {
  findmnt -rn -o TARGET | awk -v root="${TMP_ROOT}" '
    ($0 == root || index($0, root "/") == 1) && !seen[$0]++ {
      print length($0) " " $0
    }
  ' | sort -rn | cut -d' ' -f2-
}

function loop_devices_under_tmp() {
  losetup -l -n -O NAME,BACK-FILE | awk -v root="${TMP_ROOT}" '
    {
      name = $1
      $1 = ""
      sub(/^ +/, "", $0)
      sub(/ \(deleted\)$/, "", $0)

      if ((($0 == root) || index($0, root "/") == 1) && !seen[name]++) {
        print name
      }
    }
  '
}

function cleanup_requires_root() {
  if [ -n "$(mount_targets_under_tmp)" ]; then
    return 0
  fi

  if [ -n "$(loop_devices_under_tmp)" ]; then
    return 0
  fi

  if [ -e "${TMP_ROOT}" ] && [ ! -w "${TMP_ROOT}" ]; then
    return 0
  fi

  if [ -e "${OUTPUT_ROOT}" ] && [ ! -w "${OUTPUT_ROOT}" ]; then
    return 0
  fi

  return 1
}

function require_root_for_cleanup() {
  if [ "$(id -u)" -eq 0 ]; then
    return 0
  fi

  if cleanup_requires_root; then
    printf '%s\n' 'Root access is required to clean up mounted build leftovers under tmp/.'
    exec sudo -p '[sudo] Enter your password to clean BlackArch build leftovers for %p: ' bash "${BASH_SOURCE[0]}"
  fi
}

function unmount_tmp_mounts() {
  local target=''

  while IFS= read -r target; do
    if [ -z "${target}" ]; then
      continue
    fi

    if umount "${target}" 2>/dev/null; then
      continue
    fi

    printf 'Unmounting busy target with lazy unmount: %s\n' "${target}"
    umount --lazy "${target}"
  done < <(mount_targets_under_tmp)
}

function detach_tmp_loop_devices() {
  local loop_device=''

  while IFS= read -r loop_device; do
    if [ -z "${loop_device}" ]; then
      continue
    fi

    losetup -d "${loop_device}"
  done < <(loop_devices_under_tmp)
}

function remove_output_artifacts() {
  local artifact_path=''

  if [ ! -d "${OUTPUT_ROOT}" ]; then
    return 0
  fi

  while IFS= read -r artifact_path; do
    if [ -z "${artifact_path}" ]; then
      continue
    fi

    rm -f "${artifact_path}"
  done < <(find "${OUTPUT_ROOT}" -maxdepth 1 \( -type f -o -type l \) -name "${IMAGE_NAME_PREFIX}-*" -print)

  rmdir "${OUTPUT_ROOT}" 2>/dev/null || true
}

function main() {
  require_root_for_cleanup

  if [ -d "${TMP_ROOT}" ]; then
    unmount_tmp_mounts
    detach_tmp_loop_devices
    rm -rf "${TMP_ROOT}"
  fi

  remove_output_artifacts
}

main
