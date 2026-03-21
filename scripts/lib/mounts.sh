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

function create_partitioned_raw_image() {
  local image_path="${1}"
  local image_size="${2}"

  truncate -s "${image_size}" "${image_path}"
  sgdisk --align-end \
    --clear \
    --new 0:0:+1M --typecode=0:ef02 --change-name=0:'BIOS boot partition' \
    --new 0:0:+300M --typecode=0:ef00 --change-name=0:'EFI system partition' \
    --new 0:0:0 --typecode=0:8304 --change-name=0:'Arch Linux root' \
    "${image_path}"
}

function mount_new_raw_image() {
  local image_path="${1}"
  local mount_root="${2}"

  TARGET_LOOP_DEVICE="$(losetup --find --partscan --show "${image_path}")"
  export TARGET_LOOP_DEVICE
  wait_until_partitions_exist "${TARGET_LOOP_DEVICE}"

  mkfs.fat -F 32 -S 4096 "${TARGET_LOOP_DEVICE}p2"
  mkfs.btrfs "${TARGET_LOOP_DEVICE}p3"

  mount -o compress=zstd:1 "${TARGET_LOOP_DEVICE}p3" "${mount_root}"
  mount --mkdir "${TARGET_LOOP_DEVICE}p2" "${mount_root}/efi"
}

function finalize_mounted_image() {
  local mount_root="${1}"

  sync -f "${mount_root}/etc/os-release"
  fstrim --verbose "${mount_root}"
  fstrim --verbose "${mount_root}/efi" || true
}
