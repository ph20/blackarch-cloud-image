# blackarch-cloud-image

Build a `qcow2` BlackArch cloud image from an Arch-based Linux host.

This project combines:

- the modern disk/bootstrap/cloud-image flow from `arch-boxes`
- the BlackArch repository bootstrap idea from `blackarch-virtualization`
- an in-repo BlackArch setup path that avoids executing `https://blackarch.org/strap.sh` by default

The output is a compressed `qcow2` image intended for cloud or VM environments where `cloud-init` is available.

## What the image contains

The generated image includes:

- Arch Linux base system
- BlackArch repository configured inside the image
- `cloud-init`
- `qemu-guest-agent`
- Btrfs root filesystem with Zstandard compression
- GRUB configured for both BIOS and UEFI boot
- serial console support on `ttyS0`
- `systemd-networkd`, `systemd-resolved`, and `sshd`

By default, the build uses the `core` BlackArch profile: the repository is enabled, but no extra BlackArch toolset is preinstalled.

You can also:

- switch to the curated `common` profile
- append your own packages with `BLACKARCH_PACKAGES`
- resize the final image with `DISK_SIZE`
- pin the build artifact version with `BUILD_VERSION` or an explicit `build.sh` argument

## Project layout

```text
.
├── build.sh                         # Main builder entrypoint
├── Makefile                         # Helper targets: build, check-env, lint, clean
├── images/
│   ├── base.sh                      # Base image customization shared by variants
│   └── blackarch-cloud.sh           # BlackArch + cloud-init customization
└── scripts/
    ├── check-build-env.sh           # Preflight validation for host, tools, space, network
    └── setup-blackarch-repo.sh      # In-image BlackArch repository bootstrap
```

## Requirements

Build on an Arch-based Linux host.

The following commands must be available:

- `arch-chroot`
- `blockdev`
- `btrfs`
- `chattr`
- `curl`
- `fstrim`
- `gpgconf`
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
- `truncate`
- `udevadm`
- `umount`
- `sudo` when the build is started as a non-root user

Additional practical requirements:

- root privileges for loop devices, mounts, package installation, and image creation
- network access to Arch package mirrors and BlackArch resources
- enough free disk space on the filesystem that contains this repository

As a rule of thumb, keep at least:

- about **8 GiB** free for the default `core` profile
- more for `BLACKARCH_PROFILE=common`
- even more when using `BLACKARCH_PACKAGES` or a larger `DISK_SIZE`

Run the preflight checks before the first build:

```bash
make check-env
```

## Quick start

Build the default image:

```bash
make
```

If `make` is started as a non-root user, it will validate the environment first and then ask for `sudo` before invoking `./build.sh`.

The build writes detailed logs to `output/`, while the console shows only high-level progress.

## Build examples

### Default build

```bash
make
```

### Explicit build version

```bash
make BUILD_VERSION=20260320.0
```

You can also run the builder directly:

```bash
sudo ./build.sh 20260320.0
```

### Install the curated `common` BlackArch profile

```bash
sudo BLACKARCH_PROFILE=common DISK_SIZE=20G ./build.sh
```

### Add specific BlackArch packages

```bash
sudo BLACKARCH_PACKAGES="sqlmap nmap masscan" DISK_SIZE=20G ./build.sh
```

### Use the repository only, with no extra tools preinstalled

```bash
sudo BLACKARCH_PROFILE=core ./build.sh
```

## Build settings

### Version selection

- `BUILD_VERSION` — optional explicit artifact version. `make BUILD_VERSION=20260320.0` passes it through automatically, and direct `build.sh` runs also accept `sudo BUILD_VERSION=20260320.0 ./build.sh` or `sudo ./build.sh 20260320.0`.
- When no explicit version is provided, the build auto-selects the first free date-based version for the current day, for example `20260320.0`, `20260320.1`, and so on.

### General build settings

- `DEFAULT_DISK_SIZE` — initial sparse raw disk size used during bootstrap. Default: `2G`.
- `DISK_SIZE` — optional final root disk size before conversion to `qcow2`.

### BlackArch settings

- `BLACKARCH_PROFILE` — `core` or `common`. Default: `core`.
- `BLACKARCH_PACKAGES` — space-separated package list to install after the BlackArch repository is configured.
- `BLACKARCH_KEYRING_VERSION` — keyring bundle version used by the in-repo BlackArch bootstrap. Default: `20251011`.
- `BLACKARCH_KEYRING_SHA256` — optional explicit SHA256 for the selected keyring archive; required when using an unpinned custom keyring version.
- `BLACKARCH_STRAP_URL` — optional compatibility override for using an external BlackArch strap script instead of the built-in bootstrap.
- `BLACKARCH_STRAP_SHA256` — required SHA256 checksum for `BLACKARCH_STRAP_URL`.

### Image customization settings

- `IMAGE_HOSTNAME`, `IMAGE_SWAP_SIZE`, `IMAGE_LOCALE`, `IMAGE_TIMEZONE`, and `IMAGE_KEYMAP` — override first-boot image defaults while preserving the current default behavior when unset.
- `IMAGE_DEFAULT_USER`, `IMAGE_DEFAULT_USER_GECOS`, and `IMAGE_PASSWORDLESS_SUDO` — override the default cloud user identity and sudo policy. `IMAGE_PASSWORDLESS_SUDO` accepts `true` or `false`.

## Output artifacts

Successful builds produce these files in `output/`:

- `BlackArch-Linux-x86_64-cloudimg-<version>.qcow2`
- `BlackArch-Linux-x86_64-cloudimg-<version>.qcow2.SHA256`
- `BlackArch-Linux-x86_64-cloudimg-<version>.manifest`
- `BlackArch-Linux-x86_64-cloudimg-<version>.build.log`

Verify the checksum after the build:

```bash
cd output
sha256sum -c BlackArch-Linux-x86_64-cloudimg-<version>.qcow2.SHA256
```

## First boot behavior

The image is prepared for `cloud-init`-driven environments.

Current defaults baked into the image:

- root login is disabled
- SSH password authentication is disabled
- the default cloud user is `arch`
- the default cloud user gets passwordless `sudo`
- console output is available on `tty0` and `ttyS0` at `115200`

That means you should normally provide an SSH key with `cloud-init` rather than relying on a password.

Example `user-data`:

```yaml
#cloud-config
users:
  - default
ssh_authorized_keys:
  - ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA... replace-me
package_update: false
package_upgrade: false
```

Example `meta-data`:

```yaml
instance-id: blackarch-test-01
local-hostname: blackarch-test-01
```

## Local smoke test with QEMU

One practical way to validate the image locally is to boot it with a NoCloud seed image.

Create `user-data` and `meta-data` as shown above, then create a seed image with your preferred tool, for example `cloud-localds`:

```bash
cloud-localds seed.img user-data meta-data
```

Boot the image:

```bash
qemu-system-x86_64 \
  -m 4096 \
  -smp 2 \
  -nographic \
  -serial mon:stdio \
  -drive if=virtio,format=qcow2,file=output/BlackArch-Linux-x86_64-cloudimg-<version>.qcow2 \
  -drive if=virtio,format=raw,file=seed.img \
  -device virtio-net-pci \
  -enable-kvm
```

Things to verify on first boot:

- GRUB appears and the kernel boots without manual intervention
- `cloud-init` finishes successfully
- the `arch` user is created or configured as expected
- your SSH key works
- `qemu-guest-agent` is active
- networking comes up correctly

## Make targets

```bash
make help
```

Available targets:

- `make` or `make build` — run preflight checks and build the image
- `make check-env` — validate host tools, network reachability, privileges, loop devices, and free space
- `make lint` — run `bash -n` and `shellcheck`
- `make clean` — remove `output/` and `tmp/`

## Troubleshooting

### `make check-env` fails on missing commands

Install the missing host tools and run the check again.

### Not enough free disk space

Free space on the filesystem that contains this repository, or move the repository to a larger filesystem.

### Build was interrupted

The build script installs traps for `ERR`, `INT`, `TERM`, and `EXIT`, and attempts to clean up loop devices, mounts, and temporary directories automatically.

### BlackArch repository setup fails

Check:

- network connectivity to `blackarch.org`
- the selected `BLACKARCH_KEYRING_VERSION`
- whether you intentionally overrode `BLACKARCH_STRAP_URL`
- the build log in `output/*.build.log`

### Cloud image boots but SSH access does not work

Make sure you supplied an SSH public key through `cloud-init`. The image disables password-based SSH authentication by default.

## Security notes

A few defaults are convenient for automation but should be understood before production use:

- the default cloud user is configured with passwordless `sudo`
- the build downloads BlackArch repository bootstrap inputs during image creation
- the optional legacy strap path executes an external script if `BLACKARCH_STRAP_URL` is set

For stricter environments, consider forking the project and tightening the cloud-init defaults or bootstrap verification path.

## Development notes

Before sending changes:

```bash
make lint
```

Recommended follow-up automation for the repository:

- a CI job that runs `bash -n` and `shellcheck`
- an optional smoke test that boots the built image in QEMU and checks `cloud-init` completion
- release automation that publishes the `qcow2`, checksum, and build metadata

## License

See [LICENSE](LICENSE).
