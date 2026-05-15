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
- `hetzner`
  Exports `qcow2` for `hcloud-upload-image`, uses an ext4 root filesystem, keeps BIOS+UEFI boot support, installs and enables `qemu-guest-agent`, adds a Hetzner-specific `cloud-init` datasource override, permits SSH key login as both `root` and `blackarch`, keeps SSH password authentication disabled, and defaults to `4G`.

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
  `hetzner` uses ext4
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
├── VERSION                          # Canonical codebase release version (SemVer)
├── profiles/
│   ├── digitalocean.env             # DigitalOcean profile defaults
│   ├── digitalocean.sh              # Optional DigitalOcean profile hook
│   ├── digitalocean/
│   │   └── rootfs-overlay/          # DigitalOcean rootfs overlay files
│   ├── hetzner.env                  # Hetzner Cloud profile defaults
│   ├── hetzner.sh                   # Optional Hetzner profile hook
│   └── generic-qemu.env             # Generic QEMU/KVM profile defaults
├── images/
│   ├── base.sh                      # Common rootfs and bootable disk customization hooks
│   └── blackarch-cloud.sh           # BlackArch repo/profile + cloud-init customization
├── scripts/
│   ├── build-rootfs.sh              # Stage 1: build reusable rootfs artifact
│   ├── assemble-image.sh            # Stage 2: assemble bootable raw staging image
│   ├── export-image.sh              # Stage 3: export final profile artifact
│   ├── publish-r2.sh                # Publish selected image artifacts to R2
│   ├── next-build-id-r2.sh          # Resolve the next publishing build ID from R2
│   ├── build-weekly.sh              # Build weekly profiles and print publish commands
│   ├── build-weekly-publish.sh      # Weekly build then publish wrapper
│   ├── check-build-env.sh           # Host preflight checks
│   ├── clean-build-state.sh         # Remove tmp/ leftovers and output artifacts
│   ├── setup-blackarch-repo.sh      # In-image BlackArch repository bootstrap
│   └── lib/                         # Shared config, logging, manifests, mounts, validation
├── publish/                         # R2 publishing docs and non-secret env example
└── Makefile                         # Convenience targets
```

## Requirements

Build on an Arch-based Linux host with:

- root privileges for loop devices, mounts, package installation, and image creation
- network access to Arch package mirrors and BlackArch resources
- enough free disk space for the selected profile and package set

Required commands:

- `arch-chroot`
- `blkid`
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
  Required for profiles that keep an EFI system partition, such as `generic-qemu` and `hetzner`.

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

Hetzner Cloud export for `hcloud-upload-image`:

```bash
sudo IMAGE_PROFILE=hetzner ./build.sh
```

Explicit build ID:

```bash
sudo IMAGE_PROFILE=generic-qemu ./build.sh 20260320.0
```

Explicit build ID via environment:

```bash
sudo IMAGE_PROFILE=generic-qemu BUILD_ID=20260320.0 ./build.sh
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

```bash
IMAGE_PROFILE=digitalocean BUILD_ID=20260321.2 make build
```

Place both build artifacts and temporary build state under a custom workspace:

```bash
BUILD_WORKSPACE=/build make weekly-build
```

This writes artifacts under `/build/output` and temporary state under
`/build/tmp`. `make publish`, `make publish-dry-run`, and `make clean` use the
same workspace when `BUILD_WORKSPACE` is set.

Reuse an existing compatible rootfs artifact for another profile build:

```bash
sudo IMAGE_PROFILE=digitalocean BUILD_ID=20260321.2 REUSE_ROOTFS=true ./build.sh
```

Build all supported profiles sequentially with one `BUILD_ID` and one shared Stage 1 rootfs artifact:

```bash
BUILD_ID=20260321.2 make build-all
```

If a compatible rootfs tarball already exists for that `BUILD_ID`, reuse it from the first profile onward:

```bash
BUILD_ID=20260321.2 REUSE_ROOTFS=true make build-all
```

Override the profile list used by `make build-all`:

```bash
IMAGE_PROFILES="generic-qemu digitalocean hetzner" BUILD_ID=20260321.2 make build-all
```

## Publishing to R2

R2 publishing is separate from the build stages. It uploads only explicitly
selected final image outputs and build logs described by generated manifests
under the configured `output/images`; `output/` remains a temporary build
workspace, not a mirror.

Build the weekly profiles without publishing:

```bash
IMAGE_PROFILES="generic-qemu digitalocean hetzner" make weekly-build
```

After a successful build, `make weekly-build` prints the exact publish commands
for the resolved `BUILD_ID`, for example:

```bash
BUILD_ID=20260514.0 make publish-dry-run
BUILD_ID=20260514.0 make publish
```

Dry-run an existing build publish:

```bash
BUILD_ID=20260328.0 make publish-dry-run
```

Publish an existing weekly build:

```bash
BUILD_ID=20260328.0 make publish
```

Build the weekly profiles and publish:

```bash
IMAGE_PROFILES="generic-qemu digitalocean hetzner" make weekly-publish
```

Without an explicit `BUILD_ID`, the weekly wrappers ask R2 for the next default
build ID via `scripts/next-build-id-r2.sh`. The combined `weekly-publish`
target checks the required R2 publish configuration before starting the root
build. See `publish/README.md` for R2 environment setup, signing, object
layout, and verification commands.

## Versioning

The builder resolves three separate version values:

- `release_version`
  The codebase release version. This is read from the top-level `VERSION` file and must be SemVer such as `0.4.0`, `0.4.1`, `0.5.0`, or `1.0.0-rc.1`.
- `build_id`
  The concrete artifact build identity. This uses `YYYYMMDD.N`, for example `20260321.2`.
- `artifact_version`
  The combined artifact identifier: `<release_version>+<build_id>`, for example `0.4.0+20260321.2`.

`build_id` resolution order is:

1. positional argument to `./build.sh`
2. `BUILD_ID`
3. legacy `BUILD_VERSION`
4. auto-generated next `YYYYMMDD.N` based on existing files under the configured `output/`

If `BUILD_ID` and `BUILD_VERSION` are both set, they must match. Legacy `BUILD_VERSION` is only consumed when it already matches `YYYYMMDD.N`; unrelated ambient values are ignored.

Artifact filenames include both pieces of information:

- `BlackArch-Linux-x86_64-<profile>-v<release_version>+<build_id>.<ext>`
- `blackarch-rootfs-v<release_version>+<build_id>.tar.zst`

The Stage 1 rootfs tarball is profile-neutral. When `REUSE_ROOTFS=true`, the builder will reuse an existing compatible rootfs artifact instead of rebuilding Stage 1. Compatibility is checked against the rootfs manifest, including the current git commit and the Stage 1 inputs that affect the reusable rootfs contents.

The manifests remain `key=value` files and record explicit version/build metadata, including:

- `release_version`
- `build_id`
- `artifact_version`
- `git_commit`
- `git_tag`
- `profile`
- `artifact_format`
- `filesystem`
- `boot_mode`
- `built_at_utc`

When `HEAD` is not at an exact tag, `git_tag=none`.

## Release Workflow

To create a release:

1. Update `VERSION` to the new SemVer release.
2. Commit the change.
3. Optionally tag the release commit as `v<release_version>`.
4. Run one or more builds. Each build gets its own `build_id`, even when `VERSION` stays the same.

Version bump policy:

- Patch bump: bug fixes, build logic fixes, boot fixes, cloud-init fixes, ownership fixes, and other backwards-compatible maintenance.
- Minor bump: new profiles, new artifact formats, additive profile features, additive manifest fields, or additive release-workflow improvements.
- Major bump: incompatible environment variable changes, incompatible profile schema changes, incompatible manifest changes, or output naming changes that downstream automation must adapt to.
- Rebuild only: keep `VERSION` unchanged and produce a new `build_id`. Do not mint a new SemVer just to rebuild the same release.

## Configuration

Core staged-build settings:

- `VERSION`
  Top-level repository file containing the canonical SemVer `release_version`.
- `IMAGE_PROFILE`
  `generic-qemu`, `digitalocean`, or `hetzner`. Default: `generic-qemu`.
- `BUILD_ID`
  Optional explicit `YYYYMMDD.N` build identity. If unset, the builder auto-selects the next daily build number.
- `BUILD_VERSION`
  Legacy compatibility alias for `BUILD_ID`. It is only honored when it already matches `YYYYMMDD.N`. Prefer `BUILD_ID` for new automation.
- `BUILD_WORKSPACE`
  Optional build workspace root. Defaults to the repository root and must be an existing writable directory. When set, artifacts are written under `${BUILD_WORKSPACE}/output` and temporary build state under `${BUILD_WORKSPACE}/tmp`, unless `OUTPUT_ROOT` or `TMP_ROOT` override those paths directly.
- `OUTPUT_ROOT`
  Optional advanced override for the artifact output root. Defaults to `${BUILD_WORKSPACE}/output`.
- `TMP_ROOT`
  Optional advanced override for temporary build state. Defaults to `${BUILD_WORKSPACE}/tmp`.
- `REUSE_ROOTFS`
  `true` or `false`. Default: `false`. When `true`, `build.sh` reuses an existing compatible rootfs tarball for the selected `release_version` and `build_id` instead of rebuilding Stage 1.
- `IMAGE_PROFILES`
  Space-separated profile list used by `make build-all`. Default: `generic-qemu digitalocean hetzner`.
- `DISK_SIZE`
  Final raw disk size used for Stage 2 assembly.
- `DEFAULT_DISK_SIZE`
  Compatibility override used when `DISK_SIZE` is unset.
  If neither is set, the profile default is used:
  `generic-qemu` => `2G`
  `digitalocean` => `4G`
  `hetzner` => `4G`

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
  `generic-qemu` and `hetzner` resolve to `true`; `digitalocean` resolves to `false`.
- `IMAGE_HOSTNAME`
- `IMAGE_SWAP_SIZE`
- `IMAGE_LOCALE`
- `IMAGE_TIMEZONE`
- `IMAGE_KEYMAP`
- `IMAGE_DEFAULT_USER`
  Default: `blackarch`.
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

Successful builds write staged artifacts under `${BUILD_WORKSPACE}/output/`.
When `BUILD_WORKSPACE` is unset, that is the repository-local `output/`:

- `output/rootfs/blackarch-rootfs-v<release_version>+<build_id>.tar.zst`
- `output/rootfs/blackarch-rootfs-v<release_version>+<build_id>.manifest`
- `output/rootfs/blackarch-rootfs-v<release_version>+<build_id>.build.log`
- `output/images/BlackArch-Linux-x86_64-generic-qemu-v<release_version>+<build_id>.qcow2`
- `output/images/BlackArch-Linux-x86_64-generic-qemu-v<release_version>+<build_id>.qcow2.SHA256`
- `output/images/BlackArch-Linux-x86_64-generic-qemu-v<release_version>+<build_id>.manifest`
- `output/images/BlackArch-Linux-x86_64-digitalocean-v<release_version>+<build_id>.img.gz`
- `output/images/BlackArch-Linux-x86_64-digitalocean-v<release_version>+<build_id>.img.gz.SHA256`
- `output/images/BlackArch-Linux-x86_64-digitalocean-v<release_version>+<build_id>.manifest`
- `output/images/BlackArch-Linux-x86_64-hetzner-v<release_version>+<build_id>.qcow2`
- `output/images/BlackArch-Linux-x86_64-hetzner-v<release_version>+<build_id>.qcow2.SHA256`
- `output/images/BlackArch-Linux-x86_64-hetzner-v<release_version>+<build_id>.manifest`
- `output/images/BlackArch-Linux-x86_64-<profile>-v<release_version>+<build_id>.build.log`

The manifest files are simple `key=value` records.

Stage 1 writes the reusable rootfs log under `output/rootfs`. Each profile then
writes its own image log under `output/images` for the Stage 2 and Stage 3 work
performed against that rootfs.

The reusable rootfs manifest is intentionally profile-neutral. It includes the shared Stage 1 identity and configuration, including:

- `artifact_type`
- `rootfs_name`
- `artifact_name`
- `artifact_format`
- `rootfs_build_log`
- `release_version`
- `build_id`
- `artifact_version`
- `git_commit`
- `git_tag`
- `blackarch_profile`
- `blackarch_packages`
- `image_hostname`
- `image_default_user`
- `image_default_user_gecos`
- `image_locale`
- `image_timezone`
- `image_keymap`
- `image_passwordless_sudo`
- `blackarch_keyring_version`
- `blackarch_bootstrap_mode`
- `rootfs_input_fingerprint`
- `built_at_utc`

Final image manifests include:

- `artifact_type`
- `image_name`
- `artifact_name`
- `artifact_format`
- `rootfs_artifact`
- `rootfs_build_log`
- `image_build_log`
- `release_version`
- `build_id`
- `artifact_version`
- `git_commit`
- `git_tag`
- `profile`
- `filesystem`
- `boot_mode`
- `built_at_utc`

They also keep resolved build settings such as disk size, BlackArch profile/package selections, profile package/unit lists, and image customization defaults.

Verify the final checksum after a build:

```bash
cd "${BUILD_WORKSPACE:-.}/output/images"
sha256sum -c BlackArch-Linux-x86_64-generic-qemu-v<release_version>+<build_id>.qcow2.SHA256
```

or:

```bash
cd "${BUILD_WORKSPACE:-.}/output/images"
sha256sum -c BlackArch-Linux-x86_64-digitalocean-v<release_version>+<build_id>.img.gz.SHA256
```

DigitalOcean note:

- the profile now exports a gzip-compressed raw image with an `.img.gz` name
- the profile now assembles an ext4-root BIOS-only image instead of reusing the generic BIOS+UEFI layout
- the profile adds a `cloud-init` datasource override from `profiles/digitalocean/rootfs-overlay/`
- the profile preserves the base image hostname instead of accepting a potentially overlong droplet hostname from metadata
- the profile cleans `cloud-init` state from its Stage 2 hook before export
- runtime platform validation is still not implemented, so DigitalOcean-specific boot/import verification is still manual

Hetzner note:

- the profile exports a `qcow2` intended for `hcloud-upload-image --format qcow2`
- the profile hook restricts `cloud-init` datasource probing to `Hetzner` with `None` fallback while preserving the configured default cloud user
- the profile runs `growpart` and `resizefs` on every boot, matching Hetzner's standard-image behavior for resized root disks
- the profile permits SSH public-key login as both `root` and the default `blackarch` user for deployment inspection
- the profile installs a small systemd oneshot that mirrors Hetzner metadata SSH keys into the `blackarch` user's `authorized_keys`, because Hetzner vendor-data sets its own runtime default user to `root`
- the profile installs a small systemd oneshot that retriggers udev for Hetzner Cloud Volumes
- SSH password authentication remains disabled, so create Hetzner servers from this snapshot with an SSH key selected
- the default `blackarch` cloud user is created and should receive injected SSH keys
- runtime platform validation is still manual; inspect `/var/log/cloud-init.log` from the Hetzner console/rescue system if first boot customization fails

## First boot defaults

The images are prepared for `cloud-init` environments with these defaults:

- remote SSH `root` login is disabled
- SSH password authentication is disabled
- the default cloud user is `blackarch`
- the default cloud user gets passwordless `sudo` unless overridden

The `hetzner` profile currently permits SSH public-key login as both `root` and `blackarch` to make provider-specific deployment inspection easier. Password login remains disabled.

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
  Remove build leftovers under the configured `tmp/` and delete staged output artifacts.
- `publish`
  Publish an existing weekly `BUILD_ID` from the configured `output/images` to R2 without sudo.
- `publish-dry-run`
  Validate and print planned R2 uploads for an existing `BUILD_ID`.
- `weekly-build`
  Build the weekly profile set and print publish commands for the resolved `BUILD_ID`.
- `weekly-build-dry-run`
  Print the planned weekly build-only flow without building or uploading.
- `weekly-publish`
  Build the weekly profile set, then publish to R2.
- `weekly-publish-dry-run`
  Print the planned weekly build/publish commands without building or uploading.
