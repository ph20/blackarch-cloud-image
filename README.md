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

Build on an Arch-based Linux host with these commands available:

- `arch-install-scripts`
- `btrfs-progs`
- `ca-certificates`
- `curl`
- `dosfstools`
- `e2fsprogs`
- `gnupg`
- `gptfdisk`
- `qemu-img`
- `sudo` when the build is not started as `root`
- `systemd`
- `util-linux`

The build needs `root` privileges. `make` will run a preflight environment check first and, when started as a non-root user, prompt for your `sudo` password before launching `./build.sh`.
The same preflight check also verifies that the filesystem containing this repository has enough free space for the selected build configuration. As a rule of thumb, keep at least `8 GiB` free for `core` builds and more for `common` or additional BlackArch packages.
Each build also writes a versioned log file under `output/`. The console shows only high-level build steps and the final artifact paths, while detailed command output is written only to the log file.
If the build is interrupted with `Ctrl+C`, the script cleans up temporary runtime artifacts such as mounts, loop devices, and the temporary build directory before exiting.

## Usage

Build the default image:

```bash
make
```

When `make` is started as a non-root user, it will ask for `sudo` before the actual image build begins.
Detailed build output is written to `output/BlackArch-Linux-x86_64-cloudimg-<version>.build.log`.
At the end of the build, the script prints the output directory and the full paths of the generated artifacts.

Or run the builder directly:

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

Run only the preflight checks:

```bash
make check-env
```

`make check-env` validates host commands, loop devices, network reachability, `sudo` availability when needed, and estimated free space on the repository filesystem.

Show the available `make` targets:

```bash
make help
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
- `BlackArch-Linux-x86_64-cloudimg-<version>.build.log`
