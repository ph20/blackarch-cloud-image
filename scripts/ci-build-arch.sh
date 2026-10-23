#!/usr/bin/env bash

set -o nounset
set -o errexit
set -o pipefail

if [ "${GITHUB_ACTIONS:-}" != true ] || [ "$(id -u)" -ne 0 ] || [ "${BUILD_WORKSPACE:-}" != /build ]; then
  printf '%s\n' 'Run this helper through scripts/ci-build-ubuntu.sh in GitHub Actions.' >&2
  exit 1
fi

pacman -Syu --noconfirm --needed \
  archlinux-keyring arch-install-scripts btrfs-progs ca-certificates curl \
  dosfstools e2fsprogs gawk git gnupg gptfdisk gzip make qemu-img systemd \
  tar util-linux zstd

# The read-only checkout belongs to the host runner rather than container root.
git config --global --add safe.directory /repo

make check-env
bash ./build.sh "${BUILD_ID:?}"

cd "${BUILD_WORKSPACE}/output/images"
sha256sum -c -- ./*.SHA256
for image in ./*.qcow2; do
  [ -f "${image}" ] || continue
  qemu-img info "${image}"
done
