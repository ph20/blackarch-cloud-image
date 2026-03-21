#!/usr/bin/env bash

function unmount_mount_tree() {
  local mount_root="${1}"

  if ! mountpoint -q "${mount_root}"; then
    return 0
  fi

  if umount --recursive "${mount_root}"; then
    return 0
  fi

  status_line "Standard unmount failed for ${mount_root}; retrying with lazy unmount."
  umount --recursive --lazy "${mount_root}"
}

function detach_loop_device() {
  local loop_device="${1}"
  local retries=3

  while [ "${retries}" -gt 0 ]; do
    if losetup -d "${loop_device}" 2>/dev/null; then
      return 0
    fi

    udevadm settle || true
    sleep 1
    retries=$((retries - 1))
  done

  losetup -d "${loop_device}"
}

function wait_until_partitions_exist() {
  local loop_device="${1}"

  udevadm settle
  blockdev --flushbufs --rereadpt "${loop_device}"

  until [ -e "${loop_device}p3" ]; do
    sleep 1
  done
}
