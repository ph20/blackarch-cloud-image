# blackarch-cloud-image

Build staged BlackArch cloud images from an Arch-based Linux host.

The build flow is intentionally shell-only:

1. Stage 1 builds a reusable Arch + BlackArch rootfs artifact.
2. Stage 2 assembles a bootable raw disk image for a selected platform profile.
3. Stage 3 exports the final profile-specific artifact.

Supported platform profiles:

- `generic-qemu`
  Exports `qcow2` and enables `qemu-guest-agent`.
- `digitalocean`
  Exports `raw.gz` and disables `qemu-guest-agent`.

The profile layer is intentionally small today. Future platforms should be added by introducing new profile files and localized profile logic, not by cloning the whole pipeline.

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

- Btrfs root filesystem with Zstandard compression
- GRUB configured for BIOS and UEFI boot
- serial console on `tty0` and `ttyS0`
- `systemd-networkd`, `systemd-resolved`, `systemd-timesyncd`, and `sshd`

## Project layout

```text
.
├── build.sh                         # Thin user-facing orchestrator
├── profiles/
│   ├── digitalocean.env             # raw.gz export, qemu guest agent disabled
│   └── generic-qemu.env             # qcow2 export, qemu guest agent enabled
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
- `btrfs`
- `chattr`
- `curl`
- `fstrim`
- `gpgconf`
- `gzip`
- `losetup`
- `mkfs.btrfs`
- `mkfs.fat`
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

`make build` is best for the default configuration. For non-default environment variables, prefer invoking `sudo ./build.sh` directly so the settings are preserved across privilege escalation.

## Configuration

Core staged-build settings:

- `IMAGE_PROFILE`
  `generic-qemu` or `digitalocean`. Default: `generic-qemu`.
- `BUILD_VERSION`
  Optional explicit artifact version. If unset, the build auto-selects the next `YYYYMMDD.N` value.
- `DISK_SIZE`
  Final raw disk size used for Stage 2 assembly.
- `DEFAULT_DISK_SIZE`
  Compatibility default used when `DISK_SIZE` is unset. Default: `2G`.

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

## Output artifacts

Successful builds write staged artifacts under `output/`:

- `output/rootfs/blackarch-rootfs-<version>.tar.zst`
- `output/rootfs/blackarch-rootfs-<version>.manifest`
- `output/images/BlackArch-Linux-x86_64-generic-qemu-<version>.qcow2`
- `output/images/BlackArch-Linux-x86_64-generic-qemu-<version>.qcow2.SHA256`
- `output/images/BlackArch-Linux-x86_64-generic-qemu-<version>.manifest`
- `output/images/BlackArch-Linux-x86_64-digitalocean-<version>.raw.gz`
- `output/images/BlackArch-Linux-x86_64-digitalocean-<version>.raw.gz.SHA256`
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
sha256sum -c BlackArch-Linux-x86_64-digitalocean-<version>.raw.gz.SHA256
```

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
