# blackarch-cloud-image

Build BlackArch cloud images from an Arch-based Linux host.

The project creates reusable BlackArch root filesystems and exports bootable images for cloud providers and local virtualization.

## Supported profiles

| Profile | Output | Filesystem | Boot mode | Default size | Purpose |
| --- | --- | --- | --- | --- | --- |
| `generic-qemu` | `qcow2` | Btrfs | BIOS + UEFI | `2G` | Generic QEMU/KVM image. |
| `digitalocean` | `img.gz` | ext4 | BIOS | `4G` | DigitalOcean custom image import. |
| `hetzner` | `qcow2` | ext4 | BIOS + UEFI | `4G` | Hetzner Cloud upload through `hcloud-upload-image`. |

Runtime validation is not automated yet. After import, verify boot and `cloud-init` behavior on the target platform.

## Build flow

The build has three stages:

1. **Rootfs** — build a reusable Arch + BlackArch root filesystem.
2. **Image assembly** — create a bootable disk image for the selected profile.
3. **Export** — convert or compress the image into the final provider format.

This keeps the common BlackArch setup reusable while allowing each profile to control filesystem type, boot mode, packages, services, and `cloud-init` settings.

## What the image includes

Common image content:

- Arch Linux base system
- BlackArch repository setup
- BlackArch package profile: `core` or `common`
- optional extra packages from `BLACKARCH_PACKAGES`
- `cloud-init`
- OpenSSH
- GRUB bootloader
- serial console support
- `systemd-networkd`, `systemd-resolved`, `systemd-timesyncd`, and `sshd`

First-boot defaults:

- default user: `blackarch`
- password SSH login: disabled
- passwordless `sudo`: enabled for the default user
- root SSH login: disabled by default

The `hetzner` profile allows SSH key login as both `root` and `blackarch` for easier deployment inspection. Password login remains disabled.

## Requirements

Build on an Arch-based Linux host with:

- root or `sudo` access
- network access to Arch and BlackArch package sources
- enough free disk space for the selected image size and package set
- required system tools such as `pacman`, `pacstrap`, `arch-chroot`, `qemu-img`, filesystem tools, mount tools, and checksum tools

Run the preflight check before building:

```bash
make check-env
```

Profile-specific requirements:

- Btrfs tools are required for `generic-qemu`.
- FAT filesystem tools are required for profiles with UEFI support, such as `generic-qemu` and `hetzner`.

## Quick start

Build one profile:

```bash
sudo IMAGE_PROFILE=generic-qemu ./build.sh
sudo IMAGE_PROFILE=digitalocean ./build.sh
sudo IMAGE_PROFILE=hetzner ./build.sh
```

Or use the Makefile wrapper:

```bash
IMAGE_PROFILE=digitalocean make build
```

Common examples:

```bash
# Build with the larger BlackArch package profile
IMAGE_PROFILE=generic-qemu BLACKARCH_PROFILE=common DISK_SIZE=20G make build

# Add extra BlackArch packages
IMAGE_PROFILE=digitalocean BLACKARCH_PACKAGES="blackarch-officials" DISK_SIZE=20G make build

# Use an explicit build ID
sudo IMAGE_PROFILE=generic-qemu BUILD_ID=20260320.0 ./build.sh

# Reuse an existing compatible rootfs artifact
sudo IMAGE_PROFILE=digitalocean BUILD_ID=20260321.2 REUSE_ROOTFS=true ./build.sh

# Build all supported profiles with one shared rootfs artifact
BUILD_ID=20260321.2 make build-all
```

## Configuration

Most builds only need these variables:

| Variable | Default | Description |
| --- | --- | --- |
| `IMAGE_PROFILE` | `generic-qemu` | Profile to build: `generic-qemu`, `digitalocean`, or `hetzner`. |
| `BUILD_ID` | auto-generated | Build identity in `YYYYMMDD.N` format. |
| `BUILD_WORKSPACE` | repository root | Workspace root. Outputs go to `output/`; temporary state goes to `tmp/`. |
| `DISK_SIZE` | profile default | Final image disk size. |
| `BLACKARCH_PROFILE` | `core` | BlackArch package profile: `core` or `common`. |
| `BLACKARCH_PACKAGES` | empty | Extra BlackArch packages to install. |
| `REUSE_ROOTFS` | `false` | Reuse a compatible rootfs artifact instead of rebuilding Stage 1. |
| `IMAGE_PROFILES` | `generic-qemu digitalocean hetzner` | Profile list for multi-profile and weekly builds. |

Use a custom workspace:

```bash
BUILD_WORKSPACE=/build make weekly-build
```

This writes artifacts to `/build/output` and temporary build state to `/build/tmp`.

## Output

Successful builds write files under:

```text
${BUILD_WORKSPACE:-.}/output/
```

Main directories:

```text
output/rootfs/    reusable rootfs artifacts, manifests, and logs
output/images/    final images, checksums, manifests, and logs
```

Typical final images:

```text
BlackArch-Linux-x86_64-generic-qemu-v<release_version>+<build_id>.qcow2
BlackArch-Linux-x86_64-digitalocean-v<release_version>+<build_id>.img.gz
BlackArch-Linux-x86_64-hetzner-v<release_version>+<build_id>.qcow2
```

Verify a checksum:

```bash
cd "${BUILD_WORKSPACE:-.}/output/images"
sha256sum -c BlackArch-Linux-x86_64-generic-qemu-v<release_version>+<build_id>.qcow2.SHA256
```

## Publishing to R2

Publishing is separate from image building.

Build weekly profiles without publishing:

```bash
IMAGE_PROFILES="generic-qemu digitalocean hetzner" make weekly-build
```

Publish an existing build:

```bash
BUILD_ID=20260328.0 make publish-dry-run
BUILD_ID=20260328.0 make publish
```

Build and publish weekly profiles:

```bash
IMAGE_PROFILES="generic-qemu digitalocean hetzner" make weekly-publish
```

See `publish/README.md` for R2 credentials, object layout, signing, and verification details.

## Versioning

The project uses two version values:

- `release_version` — the codebase version from the top-level `VERSION` file, using SemVer.
- `build_id` — the concrete artifact build ID, using `YYYYMMDD.N`.

The final artifact version is:

```text
<release_version>+<build_id>
```

Example:

```text
0.4.0+20260321.2
```

Use a new `build_id` when rebuilding the same release. Bump `VERSION` only when the codebase release changes.

Recommended bump policy:

- patch: bug fixes and backwards-compatible maintenance
- minor: new profiles, new artifact formats, or additive features
- major: incompatible environment variables, profile schema, manifest format, or output naming changes

## Profile customization

Profiles live in `profiles/`.

A profile can define:

```text
profiles/<name>.env                 profile defaults
profiles/<name>.sh                  optional profile hook
profiles/<name>/rootfs-overlay/     optional files copied into the image rootfs
```

Add new platforms by adding a new profile instead of cloning the whole pipeline.

## Project layout

```text
.
├── build.sh                 # Main build entrypoint
├── VERSION                  # Codebase release version
├── profiles/                # Platform profiles
├── images/                  # Shared image customization scripts
├── scripts/                 # Build, export, publish, and validation helpers
├── publish/                 # R2 publishing documentation
└── Makefile                 # Convenience targets
```

## Useful make targets

```bash
make help
```

Common targets:

| Target | Description |
| --- | --- |
| `make build` | Build one profile. |
| `make build-all` | Build multiple profiles with a shared rootfs artifact. |
| `make check-env` | Validate the host build environment. |
| `make lint` | Run shell syntax checks and ShellCheck. |
| `make clean` | Remove build leftovers and output artifacts. |
| `make weekly-build` | Build the weekly profile set and print publish commands. |
| `make weekly-publish` | Build the weekly profile set and publish to R2. |
| `make publish-dry-run` | Show planned R2 uploads for an existing build. |
| `make publish` | Publish an existing build to R2. |

## Notes

- Keep provider-specific behavior inside profiles.
- Keep low-level implementation details close to the scripts that need them.
- Runtime provider validation is still manual.
