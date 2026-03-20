# blackarch-cloud-image

Standalone project for building a `qcow2` BlackArch cloud image.

The project combines:

- the modern disk/bootstrap/cloud-image pipeline from `arch-boxes`
- the BlackArch repository bootstrap idea from `blackarch-virtualization`

The result is a compressed `qcow2` image with:

- Arch Linux base system
- `cloud-init`
- `qemu-guest-agent`
- BlackArch repository configured inside the image

By default the build uses the `core` profile: the BlackArch repository is configured, but no extra BlackArch toolset is preinstalled. You can switch to `common`, and you can still append extra packages through `BLACKARCH_PACKAGES`.

The repository bootstrap now runs from the in-repo `scripts/setup-blackarch-repo.sh` flow instead of downloading and executing `https://blackarch.org/strap.sh` during the build.

## Requirements

Build on an Arch Linux host with these packages available:

- `arch-install-scripts`
- `btrfs-progs`
- `ca-certificates`
- `curl`
- `dosfstools`
- `gptfdisk`
- `qemu-img`

The build must be run as `root`.

## Usage

Build the default image:

```bash
sudo ./build.sh
```

Build with an explicit version tag:

```bash
sudo ./build.sh 20260320.0
```

Build with extra BlackArch packages preinstalled:

```bash
sudo BLACKARCH_PACKAGES="blackarch-officials" DISK_SIZE=20G ./build.sh
```

Build with the curated `common` profile from the older `packer-blackarch` project:

```bash
sudo BLACKARCH_PROFILE=common DISK_SIZE=20G ./build.sh
```

## Environment Variables

- `BLACKARCH_PROFILE`: one of `core`, `common`; defaults to `core`
- `BLACKARCH_PACKAGES`: space-separated list of packages to install after the BlackArch repository is configured
- `BLACKARCH_KEYRING_VERSION`: keyring bundle version used by the built-in BlackArch bootstrap; defaults to `20251011`
- `BLACKARCH_STRAP_URL`: optional compatibility override to run an external BlackArch strap script instead of the built-in bootstrap
- `BLACKARCH_STRAP_SHA256`: optional SHA256 checksum for that external strap script
- `DEFAULT_DISK_SIZE`: initial raw disk size used during bootstrap, defaults to `2G`
- `DISK_SIZE`: optional final root disk size for the image before conversion to `qcow2`

## Output

Artifacts are written to `output/`:

- `BlackArch-Linux-x86_64-cloudimg-<version>.qcow2`
- `BlackArch-Linux-x86_64-cloudimg-<version>.qcow2.SHA256`
