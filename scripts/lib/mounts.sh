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
  local root_partition="${2}"

  run_logged udevadm settle
  run_logged blockdev --flushbufs --rereadpt "${loop_device}"

  until [ -e "${root_partition}" ]; do
    sleep 1
  done
}

function create_partitioned_raw_image() {
  local image_path="${1}"
  local image_size="${2}"

  run_logged truncate -s "${image_size}" "${image_path}"

  case "${RESOLVED_IMAGE_BOOT_MODE}" in
    bios)
      run_logged sgdisk --align-end \
        --clear \
        --new 1:0:+1M --typecode=1:ef02 --change-name=1:'BIOS boot partition' \
        --new 2:0:0 --typecode=2:8304 --change-name=2:'Arch Linux root' \
        "${image_path}"
      ;;
    bios+uefi)
      run_logged sgdisk --align-end \
        --clear \
        --new 1:0:+1M --typecode=1:ef02 --change-name=1:'BIOS boot partition' \
        --new 2:0:+"${RESOLVED_IMAGE_EFI_PARTITION_SIZE}" --typecode=2:ef00 --change-name=2:'EFI system partition' \
        --new 3:0:0 --typecode=3:8304 --change-name=3:'Arch Linux root' \
        "${image_path}"
      ;;
    *)
      printf 'Unsupported boot mode: %s\n' "${RESOLVED_IMAGE_BOOT_MODE}" >&2
      return 1
      ;;
  esac
}

function set_target_partition_paths() {
  TARGET_BIOS_PARTITION="${TARGET_LOOP_DEVICE}p1"
  TARGET_EFI_PARTITION=''

  case "${RESOLVED_IMAGE_BOOT_MODE}" in
    bios)
      TARGET_ROOT_PARTITION="${TARGET_LOOP_DEVICE}p2"
      ;;
    bios+uefi)
      TARGET_EFI_PARTITION="${TARGET_LOOP_DEVICE}p2"
      TARGET_ROOT_PARTITION="${TARGET_LOOP_DEVICE}p3"
      ;;
    *)
      printf 'Unsupported boot mode: %s\n' "${RESOLVED_IMAGE_BOOT_MODE}" >&2
      return 1
      ;;
  esac

  export TARGET_BIOS_PARTITION
  export TARGET_EFI_PARTITION
  export TARGET_ROOT_PARTITION
}

function format_root_filesystem() {
  case "${RESOLVED_IMAGE_ROOT_FS_TYPE}" in
    btrfs)
      run_logged mkfs.btrfs "${TARGET_ROOT_PARTITION}"
      ;;
    ext4)
      run_logged mkfs.ext4 -F -q "${TARGET_ROOT_PARTITION}"
      ;;
    *)
      printf 'Unsupported root filesystem type: %s\n' "${RESOLVED_IMAGE_ROOT_FS_TYPE}" >&2
      return 1
      ;;
  esac
}

function mount_root_filesystem() {
  local mount_root="${1}"

  case "${RESOLVED_IMAGE_ROOT_FS_TYPE}" in
    btrfs)
      run_logged mount -o compress=zstd:1 "${TARGET_ROOT_PARTITION}" "${mount_root}"
      ;;
    ext4)
      run_logged mount "${TARGET_ROOT_PARTITION}" "${mount_root}"
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
  set_target_partition_paths
  wait_until_partitions_exist "${TARGET_LOOP_DEVICE}" "${TARGET_ROOT_PARTITION}"

  if [ -n "${TARGET_EFI_PARTITION}" ]; then
    run_logged mkfs.fat -F 32 -S 4096 "${TARGET_EFI_PARTITION}"
  fi

  format_root_filesystem

  mount_root_filesystem "${mount_root}"

  if [ -n "${TARGET_EFI_PARTITION}" ]; then
    run_logged mount --mkdir "${TARGET_EFI_PARTITION}" "${mount_root}/efi"
  fi

  capture_mounted_filesystem_identifiers "${mount_root}"
}

function finalize_mounted_image() {
  local mount_root="${1}"

  run_logged sync -f "${mount_root}/etc/os-release"
  run_logged fstrim --verbose "${mount_root}"

  if [ -n "${TARGET_EFI_PARTITION:-}" ]; then
    run_logged fstrim --verbose "${mount_root}/efi" || true
  fi
}

function capture_mounted_filesystem_identifiers() {
  local mount_root="${1}"

  TARGET_ROOT_FS_UUID="$(findmnt -rn -o UUID --target "${mount_root}")"
  TARGET_ROOT_PARTUUID="$(findmnt -rn -o PARTUUID --target "${mount_root}")"
  TARGET_EFI_FS_UUID=''
  TARGET_EFI_PARTUUID=''

  if [ -z "${TARGET_ROOT_FS_UUID}" ]; then
    printf 'Failed to resolve root filesystem UUID for %s\n' "${mount_root}" >&2
    return 1
  fi

  if [ -n "${TARGET_EFI_PARTITION:-}" ]; then
    TARGET_EFI_FS_UUID="$(findmnt -rn -o UUID --target "${mount_root}/efi")"
    TARGET_EFI_PARTUUID="$(findmnt -rn -o PARTUUID --target "${mount_root}/efi")"

    if [ -z "${TARGET_EFI_FS_UUID}" ]; then
      printf 'Failed to resolve EFI filesystem UUID for %s/efi\n' "${mount_root}" >&2
      return 1
    fi
  fi

  export TARGET_ROOT_FS_UUID
  export TARGET_ROOT_PARTUUID
  export TARGET_EFI_FS_UUID
  export TARGET_EFI_PARTUUID
}
