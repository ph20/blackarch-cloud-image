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

By default the build enables the BlackArch repository but does not install the full BlackArch toolset. If you want packages baked into the image, pass them through `BLACKARCH_PACKAGES`.

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

## Environment Variables

- `BLACKARCH_PACKAGES`: space-separated list of packages to install after the BlackArch repository is configured
- `BLACKARCH_STRAP_URL`: override URL for the BlackArch bootstrap script
- `BLACKARCH_STRAP_SHA256`: optional SHA256 checksum for the downloaded strap script
- `DEFAULT_DISK_SIZE`: initial raw disk size used during bootstrap, defaults to `2G`
- `DISK_SIZE`: optional final root disk size for the image before conversion to `qcow2`

## Output

Artifacts are written to `output/`:

- `BlackArch-Linux-x86_64-cloudimg-<version>.qcow2`
- `BlackArch-Linux-x86_64-cloudimg-<version>.qcow2.SHA256`
