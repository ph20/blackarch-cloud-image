#!/usr/bin/env bash

function mount_targets_under_root() {
  local mount_root="${1}"

  findmnt -rn -o TARGET | awk -v root="${mount_root}" '
    ($0 == root || index($0, root "/") == 1) && !seen[$0]++ {
      print length($0) " " $0
    }
  ' | sort -rn | cut -d' ' -f2-
}

function unmount_mount_tree() {
  local mount_root="${1}"
  local target=''

  while IFS= read -r target; do
    if [ -z "${target}" ]; then
      continue
    fi

    log_command umount "${target}"
    if umount "${target}" 2>/dev/null; then
      continue
    fi

    status_line "Standard unmount failed for ${target}; retrying with lazy unmount."
    run_logged umount --lazy "${target}"
  done < <(mount_targets_under_root "${mount_root}")
}

function detach_loop_device() {
  local loop_device="${1}"
  local retries=3

  while [ "${retries}" -gt 0 ]; do
    log_command losetup -d "${loop_device}"
    if losetup -d "${loop_device}" 2>/dev/null; then
      return 0
    fi

    run_logged udevadm settle || true
    sleep 1
    retries=$((retries - 1))
  done

  run_logged losetup -d "${loop_device}"
}

function wait_until_partitions_exist() {
  local loop_device="${1}"

  run_logged udevadm settle
  run_logged blockdev --flushbufs --rereadpt "${loop_device}"

  until [ -e "${loop_device}p3" ]; do
    sleep 1
  done
}

function create_partitioned_raw_image() {
  local image_path="${1}"
  local image_size="${2}"

  run_logged truncate -s "${image_size}" "${image_path}"
  run_logged sgdisk --align-end \
    --clear \
    --new 0:0:+1M --typecode=0:ef02 --change-name=0:'BIOS boot partition' \
    --new 0:0:+300M --typecode=0:ef00 --change-name=0:'EFI system partition' \
    --new 0:0:0 --typecode=0:8304 --change-name=0:'Arch Linux root' \
    "${image_path}"
}

function format_root_filesystem() {
  local root_partition="${1}"

  case "${RESOLVED_IMAGE_ROOT_FS_TYPE}" in
    btrfs)
      run_logged mkfs.btrfs "${root_partition}"
      ;;
    ext4)
      run_logged mkfs.ext4 -F -q "${root_partition}"
      ;;
    *)
      printf 'Unsupported root filesystem type: %s\n' "${RESOLVED_IMAGE_ROOT_FS_TYPE}" >&2
      return 1
      ;;
  esac
}

function mount_root_filesystem() {
  local root_partition="${1}"
  local mount_root="${2}"

  case "${RESOLVED_IMAGE_ROOT_FS_TYPE}" in
    btrfs)
      run_logged mount -o compress=zstd:1 "${root_partition}" "${mount_root}"
      ;;
    ext4)
      run_logged mount "${root_partition}" "${mount_root}"
      ;;
    *)
      printf 'Unsupported root filesystem type: %s\n' "${RESOLVED_IMAGE_ROOT_FS_TYPE}" >&2
      return 1
      ;;
  esac
}

function mount_new_raw_image() {
  local image_path="${1}"
  local mount_root="${2}"

  log_command losetup --find --partscan --show "${image_path}"
  TARGET_LOOP_DEVICE="$(losetup --find --partscan --show "${image_path}")"
  export TARGET_LOOP_DEVICE
  wait_until_partitions_exist "${TARGET_LOOP_DEVICE}"

  run_logged mkfs.fat -F 32 -S 4096 "${TARGET_LOOP_DEVICE}p2"
  format_root_filesystem "${TARGET_LOOP_DEVICE}p3"

  mount_root_filesystem "${TARGET_LOOP_DEVICE}p3" "${mount_root}"
  run_logged mount --mkdir "${TARGET_LOOP_DEVICE}p2" "${mount_root}/efi"
}

function finalize_mounted_image() {
  local mount_root="${1}"

  run_logged sync -f "${mount_root}/etc/os-release"
  run_logged fstrim --verbose "${mount_root}"
  run_logged fstrim --verbose "${mount_root}/efi" || true
}
