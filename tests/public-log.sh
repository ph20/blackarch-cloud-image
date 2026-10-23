#!/usr/bin/env bash

set -o nounset
set -o errexit
set -o pipefail

TEST_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP="$(mktemp -d)"
trap 'rm -rf "${TEST_TMP}"' EXIT

# shellcheck source=scripts/lib/public-log.sh
source "${TEST_REPO}/scripts/lib/public-log.sh"

PROJECT_ROOT='/srv/checkout [a]&b'

{
  printf 'Raw output before context: %s/scripts/build-rootfs.sh\n' "${PROJECT_ROOT}"
  printf '+ bash %q/scripts/build-rootfs.sh 20261023.0\n' "${PROJECT_ROOT}"
  printf '%s\n' \
    'Build workspace: /build' \
    'Output root: /build/output' \
    'Temporary root: /build/tmp' \
    '+ tar -C /build/tmp/build-v0.5.0/rootfs -f /build/output/rootfs/image.tar.zst' \
    'Guest paths: /etc/cloud/cloud.cfg /usr/bin/pacman /dev/loop0 /boot/grub/grub.cfg' \
    'URL: https://example.org/build/scripts/build-rootfs.sh' \
    '+ bash /old/checkout/scripts/assemble-image.sh 20261023.0' \
    "Running profile hook 'finalize' from /old/checkout/profiles/hetzner.sh" \
    'Build workspace: /old builder/[x]&' \
    'Output root: /old builder/[x]&/output' \
    'Temporary root: /old builder/[x]&/tmp' \
    'tool output: /old builder/[x]&/tmp/tree: trimmed'
  printf '+ mkdir -p %q/tmp/tree\n' '/old builder/[x]&'
} >"${TEST_TMP}/original.log"
cp "${TEST_TMP}/original.log" "${TEST_TMP}/unchanged.log"
sanitize_public_build_log "${TEST_TMP}/original.log" "${TEST_TMP}/public.log"
cmp "${TEST_TMP}/original.log" "${TEST_TMP}/unchanged.log"
if grep -Eq '/srv/|/old/' "${TEST_TMP}/public.log"; then
  printf '%s\n' 'Checkout path leaked in sanitized fixture' >&2
  exit 1
fi
grep -Fx '+ bash [repo]/scripts/build-rootfs.sh 20261023.0' "${TEST_TMP}/public.log"
grep -Fx '+ tar -C /build/tmp/build-v0.5.0/rootfs -f /build/output/rootfs/image.tar.zst' "${TEST_TMP}/public.log"
grep -Fx 'Guest paths: /etc/cloud/cloud.cfg /usr/bin/pacman /dev/loop0 /boot/grub/grub.cfg' "${TEST_TMP}/public.log"
grep -Fx 'URL: https://example.org/build/scripts/build-rootfs.sh' "${TEST_TMP}/public.log"
grep -Fx 'Build workspace: /build' "${TEST_TMP}/public.log"

# Exercise the real publisher, replacing only AWS with a local upload recorder.
# Tiny artifacts avoid root access, image builds, credentials, and network use.
mkdir -p "${TEST_TMP}/workspace/output/images" "${TEST_TMP}/workspace/output/rootfs" "${TEST_TMP}/bin" "${TEST_TMP}/uploads"
rootfs_log='blackarch-rootfs-v0.5.0+20261023.0.build.log'
cp "${TEST_TMP}/original.log" "${TEST_TMP}/workspace/output/rootfs/${rootfs_log}"
for profile in generic-qemu hetzner; do
  image_base="BlackArch-Linux-x86_64-${profile}-v0.5.0+20261023.0"
  printf 'test artifact\n' >"${TEST_TMP}/workspace/output/images/${image_base}.qcow2"
  (
    cd "${TEST_TMP}/workspace/output/images"
    sha256sum "${image_base}.qcow2" >"${image_base}.qcow2.SHA256"
  )
  cp "${TEST_TMP}/original.log" "${TEST_TMP}/workspace/output/images/${image_base}.build.log"
  cat >"${TEST_TMP}/workspace/output/images/${image_base}.manifest" <<EOF
artifact_type=image
artifact_name=${image_base}.qcow2
artifact_format=qcow2
release_version=0.5.0
build_id=20261023.0
artifact_version=0.5.0+20261023.0
rootfs_artifact=blackarch-rootfs-v0.5.0+20261023.0.tar.zst
rootfs_build_log=${rootfs_log}
image_build_log=${image_base}.build.log
profile=${profile}
filesystem=ext4
boot_mode=bios+uefi
built_at_utc=2026-10-23T20:25:09Z
EOF
done

cat >"${TEST_TMP}/bin/aws" <<'SH'
#!/usr/bin/env bash
set -eu
while [ "$#" -gt 0 ]; do
  case "$1" in
    s3api) exit 1 ;;
    s3)
      [ "$2" = cp ]
      cp "$3" "${TEST_UPLOADS}/${4##*/}"
      printf '%s\n' "$4" >>"${TEST_UPLOADS}/keys"
      exit 0
      ;;
  esac
  shift
done
exit 1
SH
chmod +x "${TEST_TMP}/bin/aws"

PATH="${TEST_TMP}/bin:${PATH}" TEST_UPLOADS="${TEST_TMP}/uploads" \
  BUILD_WORKSPACE="${TEST_TMP}/workspace" OUTPUT_ROOT='' TMP_ROOT='' \
  ROOTFS_OUTPUT_DIR='' IMAGE_OUTPUT_DIR='' \
  R2_BUCKET=test R2_ENDPOINT_URL=https://r2.invalid R2_PUBLIC_BASE_URL=https://artifacts.invalid \
  AWS_PROFILE='' AWS_CLI_EXTRA_ARGS='' \
  bash "${TEST_REPO}/scripts/publish-r2.sh" --build-id 20261023.0 --no-sign >"${TEST_TMP}/publish.log" 2>&1

[ "$(grep -c "${rootfs_log}" "${TEST_TMP}/uploads/keys")" -eq 1 ]
for uploaded_log in "${TEST_TMP}/uploads/"*.build.log; do
  cmp "${TEST_TMP}/public.log" "${uploaded_log}"
done
cmp "${TEST_TMP}/original.log" "${TEST_TMP}/workspace/output/rootfs/${rootfs_log}"
printf '%s\n' 'Public-log sanitization and offline publishing checks passed.'
