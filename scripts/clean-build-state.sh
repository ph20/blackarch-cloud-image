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

CLEANED_ANY=0

function log_cleanup_action() {
  CLEANED_ANY=1
  printf '%s\n' "${1}"
}

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
    printf 'Root access is required to clean up mounted build leftovers under %s.\n' "${TMP_ROOT}"
    exec sudo --preserve-env=BUILD_WORKSPACE,OUTPUT_ROOT,TMP_ROOT,BUILD_WORKDIR \
      -p '[sudo] Enter your password to clean BlackArch build leftovers for %p: ' \
      bash "${BASH_SOURCE[0]}"
  fi
}

function unmount_tmp_mounts() {
  local target=''
  local attempts=3

  while [ "${attempts}" -gt 0 ]; do
    while IFS= read -r target; do
      if [ -z "${target}" ]; then
        continue
      fi

      if umount "${target}" 2>/dev/null; then
        log_cleanup_action "Unmounted tmp mount: ${target}"
        continue
      fi

      log_cleanup_action "Lazy-unmounting busy tmp mount: ${target}"
      umount --lazy "${target}"
    done < <(mount_targets_under_tmp)

    if [ -z "$(mount_targets_under_tmp)" ]; then
      return 0
    fi

    sleep 1
    attempts=$((attempts - 1))
  done
}

function remove_tmp_tree() {
  local attempts=3

  log_cleanup_action "Removing tmp build state: ${TMP_ROOT}"

  while [ "${attempts}" -gt 0 ]; do
    if rm -rf --one-file-system "${TMP_ROOT}" 2>/dev/null; then
      return 0
    fi

    unmount_tmp_mounts
    sleep 1
    attempts=$((attempts - 1))
  done

  rm -rf --one-file-system "${TMP_ROOT}"
}

function detach_tmp_loop_devices() {
  local loop_device=''

  while IFS= read -r loop_device; do
    if [ -z "${loop_device}" ]; then
      continue
    fi

    losetup -d "${loop_device}"
    log_cleanup_action "Detached tmp loop device: ${loop_device}"
  done < <(loop_devices_under_tmp)
}

function remove_output_artifacts() {
  local artifact_dir=''
  local legacy_artifact=''

  if [ ! -d "${OUTPUT_ROOT}" ]; then
    return 0
  fi

  for artifact_dir in "${OUTPUT_ROOT}/rootfs" "${OUTPUT_ROOT}/images"; do
    if [ -e "${artifact_dir}" ]; then
      log_cleanup_action "Removing output artifacts: ${artifact_dir}"
      rm -rf "${artifact_dir}"
    fi
  done

  while IFS= read -r legacy_artifact; do
    if [ -z "${legacy_artifact}" ]; then
      continue
    fi

    log_cleanup_action "Removing legacy output artifact: ${legacy_artifact}"
    rm -f "${legacy_artifact}"
  done < <(find "${OUTPUT_ROOT}" -maxdepth 1 \( -type f -o -type l \) -name 'BlackArch-Linux-x86_64-cloudimg-*')

  rmdir "${OUTPUT_ROOT}" 2>/dev/null || true
}

function main() {
  require_root_for_cleanup

  if [ -d "${TMP_ROOT}" ]; then
    unmount_tmp_mounts
    detach_tmp_loop_devices
    remove_tmp_tree
  fi

  remove_output_artifacts

  if [ "${CLEANED_ANY}" -eq 0 ]; then
    printf '%s\n' 'Nothing to clean.'
  fi
}

main
