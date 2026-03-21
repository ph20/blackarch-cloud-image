# blackarch-cloud-image

Build staged BlackArch cloud images from an Arch-based Linux host.

The build flow is intentionally shell-only:

1. Stage 1 builds a reusable Arch + BlackArch rootfs artifact.
2. Stage 2 assembles a bootable raw disk image for a selected platform profile.
3. Stage 3 exports the final profile-specific artifact.

Supported platform profiles:

- `generic-qemu`
  Exports `qcow2`, uses a Btrfs root filesystem, installs and enables `qemu-guest-agent`, defaults to `2G`, and keeps the current BIOS+UEFI boot path.
- `digitalocean`
  Exports `img.gz`, uses an ext4 root filesystem, keeps a BIOS-only boot path, skips `qemu-guest-agent`, adds a DigitalOcean-specific `cloud-init` datasource override, cleans `cloud-init` state before packaging, and defaults to `4G`.

Profile customization is localized through:

- `profiles/<name>.env`
  Profile defaults and the supported `PROFILE_*` settings.
- `profiles/<name>.sh`
  Optional shell hook for advanced profile-specific logic.
- `profiles/<name>/rootfs-overlay/`
  Optional files copied into the mounted image root during Stage 2 without preserving host uid/gid from the build checkout.

Future platforms should be added by introducing new profile files and localized profile logic, not by cloning the whole pipeline.

Runtime boot validation is not implemented yet. This repository only builds the staged artifacts.

## What the build contains

The common rootfs stage includes:

- Arch Linux base system
- `cloud-init`
- `openssh`
- BlackArch repository bootstrap using the in-repo setup script by default
- the selected BlackArch logical profile: `core` or `common`
- optional extra packages from `BLACKARCH_PACKAGES`

The assembled image includes:

- GRUB configured per profile boot mode
- kernel root arguments normalized to stable filesystem UUIDs instead of loop-device paths
- serial console on `tty0` and `ttyS0`
- `systemd-networkd`, `systemd-resolved`, `systemd-timesyncd`, and `sshd`
- profile-specific root filesystem behavior:
  `generic-qemu` uses Btrfs with Zstandard compression
  `digitalocean` uses ext4
- Stage 1 suppresses the early `mkinitcpio` package hook for the reusable rootfs tree
- Stage 1 recreates the kernel preset and `/boot/vmlinuz-*` copy needed for Stage 2 finalization without generating initramfs yet
- Stage 1 now renders the preset from the upstream `mkinitcpio` template, resolves all known placeholders, and fails early if any `%...%` token remains
- Stage 2 rebuilds the final initramfs after the real image root filesystem is mounted, skipping the `autodetect` hook so cloud drivers are not stripped based on the build host
- Stage 2 generates the final `grub.cfg` only after the initramfs exists, then validates that the boot config contains both `linux` and `initrd` entries without host loop-device paths
- Stage 2 validates that `/`, `/etc`, `/etc/cloud`, and `/etc/cloud/cloud.cfg.d` remain root-owned after profile overlays and hooks run

## Project layout

```text
.
├── build.sh                         # Thin user-facing orchestrator
├── profiles/
│   ├── digitalocean.env             # DigitalOcean profile defaults
│   ├── digitalocean.sh              # Optional DigitalOcean profile hook
│   ├── digitalocean/
│   │   └── rootfs-overlay/          # DigitalOcean rootfs overlay files
│   └── generic-qemu.env             # Generic QEMU/KVM profile defaults
├── images/
│   ├── base.sh                      # Common rootfs and bootable disk customization hooks
│   └── blackarch-cloud.sh           # BlackArch repo/profile + cloud-init customization
├── scripts/
│   ├── build-rootfs.sh              # Stage 1: build reusable rootfs artifact
│   ├── assemble-image.sh            # Stage 2: assemble bootable raw staging image
│   ├── export-image.sh              # Stage 3: export final profile artifact
│   ├── check-build-env.sh           # Host preflight checks
│   ├── clean-build-state.sh         # Remove tmp/ leftovers and output artifacts
│   ├── setup-blackarch-repo.sh      # In-image BlackArch repository bootstrap
│   └── lib/                         # Shared config, logging, manifests, mounts, validation
└── Makefile                         # Convenience targets
```

## Requirements

Build on an Arch-based Linux host with:

- root privileges for loop devices, mounts, package installation, and image creation
- network access to Arch package mirrors and BlackArch resources
- enough free disk space for the selected profile and package set

Required commands:

- `arch-chroot`
- `blockdev`
- `curl`
- `fstrim`
- `gpgconf`
- `gzip`
- `losetup`
- `mkfs.ext4`
- `mount`
- `mountpoint`
- `pacman`
- `pacstrap`
- `qemu-img`
- `sha256sum`
- `sgdisk`
- `tar`
- `truncate`
- `udevadm`
- `umount`
- `zstd`
- `sudo` when the build is started as a non-root user

Additional commands are required by profile behavior:

- `btrfs`, `chattr`, and `mkfs.btrfs`
  Required for Btrfs-root profiles such as `generic-qemu`.
- `mkfs.fat`
  Required for profiles that keep an EFI system partition, such as `generic-qemu`.

Run the preflight checks before building:

```bash
make check-env
```

## Build examples

Default build for `generic-qemu`:

```bash
sudo IMAGE_PROFILE=generic-qemu ./build.sh
```

DigitalOcean export:

```bash
sudo IMAGE_PROFILE=digitalocean ./build.sh
```

Explicit build version:

```bash
sudo IMAGE_PROFILE=generic-qemu ./build.sh 20260320.0
```

Curated `common` BlackArch profile:

```bash
sudo IMAGE_PROFILE=generic-qemu BLACKARCH_PROFILE=common DISK_SIZE=20G ./build.sh
```

Additional BlackArch packages:

```bash
sudo IMAGE_PROFILE=digitalocean BLACKARCH_PACKAGES="blackarch-officials" DISK_SIZE=20G ./build.sh
```

You can also run the convenience target:

```bash
make build
```

`make build` preserves the supported image/build environment variables across `sudo`, so profile and package overrides work there too.

Examples:

```bash
IMAGE_PROFILE=digitalocean make build
```

```bash
IMAGE_PROFILE=generic-qemu BLACKARCH_PROFILE=common DISK_SIZE=20G make build
```

## Configuration

Core staged-build settings:

- `IMAGE_PROFILE`
  `generic-qemu` or `digitalocean`. Default: `generic-qemu`.
- `BUILD_VERSION`
  Optional explicit artifact version. If unset, the build auto-selects the next `YYYYMMDD.N` value.
- `DISK_SIZE`
  Final raw disk size used for Stage 2 assembly.
- `DEFAULT_DISK_SIZE`
  Compatibility override used when `DISK_SIZE` is unset.
  If neither is set, the profile default is used:
  `generic-qemu` => `2G`
  `digitalocean` => `4G`

BlackArch settings:

- `BLACKARCH_PROFILE`
  `core` or `common`. Default: `core`.
- `BLACKARCH_PACKAGES`
  Space-separated extra packages installed after the BlackArch repository is enabled.
- `BLACKARCH_KEYRING_VERSION`
  Keyring bundle version used by the built-in BlackArch bootstrap. Default: `20251011`.
- `BLACKARCH_KEYRING_SHA256`
  Optional explicit SHA256 for the selected keyring archive. Required when using an unpinned custom keyring version.
- `BLACKARCH_STRAP_URL`
  Optional compatibility override for using an external BlackArch strap script.
- `BLACKARCH_STRAP_SHA256`
  Required checksum for `BLACKARCH_STRAP_URL`.

Image customization settings:

- `IMAGE_ENABLE_QEMU_GUEST_AGENT`
  Optional override. When unset, the selected profile decides the default.
  `generic-qemu` resolves to `true`; `digitalocean` resolves to `false`.
- `IMAGE_HOSTNAME`
- `IMAGE_SWAP_SIZE`
- `IMAGE_LOCALE`
- `IMAGE_TIMEZONE`
- `IMAGE_KEYMAP`
- `IMAGE_DEFAULT_USER`
- `IMAGE_DEFAULT_USER_GECOS`
- `IMAGE_PASSWORDLESS_SUDO`

## Profile Customization Model

Each profile is resolved from `profiles/<name>.env` and can optionally add:

- `profiles/<name>.sh`
  A hook script that defines `profile_hook()`. The current pipeline calls it during Stage 2 finalization.
- `profiles/<name>/rootfs-overlay/`
  A filesystem tree copied into the mounted image root before bootloader installation.

Supported profile variables:

- `PROFILE_ID`
- `PROFILE_NAME_SUFFIX`
- `PROFILE_FINAL_FORMAT`
- `PROFILE_ROOT_FS_TYPE`
- `PROFILE_DEFAULT_DISK_SIZE`
- `PROFILE_BOOT_MODE`
  Supported values: `bios`, `bios+uefi`
- `PROFILE_EFI_PARTITION_SIZE`
  Used when `PROFILE_BOOT_MODE=bios+uefi`
- `PROFILE_PACMAN_PACKAGES`
  Space-separated packages installed in Stage 2
- `PROFILE_ENABLE_SYSTEMD_UNITS`
  Space-separated units enabled in Stage 2
- `PROFILE_DISABLE_SYSTEMD_UNITS`
  Space-separated units disabled in Stage 2
- `PROFILE_ROOTFS_OVERLAY_DIR`
  Optional overlay path, resolved relative to `profiles/` when not absolute
- `PROFILE_HOOK_SCRIPT`
  Optional hook path, resolved relative to `profiles/` when not absolute

Minimal example for a new profile:

```bash
# profiles/example.env
#!/usr/bin/env bash
# shellcheck disable=SC2034
PROFILE_ID="example"
PROFILE_NAME_SUFFIX="example"
PROFILE_FINAL_FORMAT="qcow2"
PROFILE_ROOT_FS_TYPE="ext4"
PROFILE_DEFAULT_DISK_SIZE="4G"
PROFILE_BOOT_MODE="bios"
PROFILE_EFI_PARTITION_SIZE=""
PROFILE_PACMAN_PACKAGES="qemu-guest-agent"
PROFILE_ENABLE_SYSTEMD_UNITS="qemu-guest-agent.service"
PROFILE_DISABLE_SYSTEMD_UNITS=""
PROFILE_ROOTFS_OVERLAY_DIR="example/rootfs-overlay"
PROFILE_HOOK_SCRIPT="example.sh"
```

If `profiles/example/rootfs-overlay/` exists, its files are copied into the target rootfs during Stage 2. If `profiles/example.sh` exists, it can define:

```bash
#!/usr/bin/env bash

function profile_hook() {
  local hook_name="${1}"

  case "${hook_name}" in
    finalize)
      :
      ;;
  esac
}
```

## Output artifacts

Successful builds write staged artifacts under `output/`:

- `output/rootfs/blackarch-rootfs-<version>.tar.zst`
- `output/rootfs/blackarch-rootfs-<version>.manifest`
- `output/images/BlackArch-Linux-x86_64-generic-qemu-<version>.qcow2`
- `output/images/BlackArch-Linux-x86_64-generic-qemu-<version>.qcow2.SHA256`
- `output/images/BlackArch-Linux-x86_64-generic-qemu-<version>.manifest`
- `output/images/BlackArch-Linux-x86_64-digitalocean-<version>.img.gz`
- `output/images/BlackArch-Linux-x86_64-digitalocean-<version>.img.gz.SHA256`
- `output/images/BlackArch-Linux-x86_64-digitalocean-<version>.manifest`
- `output/images/BlackArch-Linux-x86_64-<profile>-<version>.build.log`

The manifest files are simple `key=value` records with the resolved build metadata for the rootfs and final image artifacts.

Verify the final checksum after a build:

```bash
cd output/images
sha256sum -c BlackArch-Linux-x86_64-generic-qemu-<version>.qcow2.SHA256
```

or:

```bash
cd output/images
sha256sum -c BlackArch-Linux-x86_64-digitalocean-<version>.img.gz.SHA256
```

DigitalOcean note:

- the profile now exports a gzip-compressed raw image with an `.img.gz` name
- the profile now assembles an ext4-root BIOS-only image instead of reusing the generic BIOS+UEFI layout
- the profile adds a `cloud-init` datasource override from `profiles/digitalocean/rootfs-overlay/`
- the profile preserves the base image hostname instead of accepting a potentially overlong droplet hostname from metadata
- the profile cleans `cloud-init` state from its Stage 2 hook before export
- runtime platform validation is still not implemented, so DigitalOcean-specific boot/import verification is still manual

## First boot defaults

The images are prepared for `cloud-init` environments with these defaults:

- root login is disabled
- SSH password authentication is disabled
- the default cloud user is `arch`
- the default cloud user gets passwordless `sudo` unless overridden

Manual boot/runtime validation is still your responsibility. This repository does not yet provide a `validate-image.sh`, QEMU smoke-boot stage, or provider-specific runtime checks.

## Make targets

```bash
make help
```

Available targets:

- `build`
  Run preflight checks and then invoke `./build.sh`.
- `check-env`
  Validate the host build environment.
- `lint`
  Run `bash -n` and `shellcheck`.
- `clean`
  Remove build leftovers under `tmp/` and delete staged output artifacts.
