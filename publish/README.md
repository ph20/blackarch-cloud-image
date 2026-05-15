# R2 Publishing

This workflow publishes explicitly selected BlackArch image build outputs from
the configured `output/images` directory to Cloudflare R2. R2 is the canonical
artifact store; local `output/` is only a temporary build workspace.

The publishing scripts upload direct object keys. They do not use `aws s3 sync`
and do not create a local artifact mirror.

## Required Tools

- `aws` CLI
- `jq`
- `gpg`
- `sha256sum`

## Configuration

Required environment:

- `R2_BUCKET`
- `R2_ENDPOINT_URL`
- `R2_PUBLIC_BASE_URL`
- `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY`, unless using `AWS_PROFILE`

Optional environment:

- `AWS_PROFILE`, when using AWS CLI profile credentials instead of direct env credentials
- `GPG_SIGNING_KEY`, recommended for selecting the `packages@ph20.org` signing key
- `BUILD_WORKSPACE`, when publishing artifacts built outside the repository-local workspace

Start from the non-secret example:

```bash
cp publish/env.r2.example publish/env.r2.local
```

Edit/export the values manually. Configure AWS access key and secret material
in `publish/env.r2.local`, with `aws configure --profile ...`, or through
another secret manager.

To use direct env credentials:

```bash
source publish/env.r2.local
```

To use an AWS CLI profile instead, omit `AWS_ACCESS_KEY_ID` and
`AWS_SECRET_ACCESS_KEY` and set:

```bash
export AWS_PROFILE="r2-ph20"
```

## Dry Run

```bash
BUILD_ID=20260328.0 make publish-dry-run
```

Dry-run mode validates local manifests, files, checksums, the per-image build
logs, and the shared rootfs build log, then prints the planned object keys,
content types, cache-control values, and public URLs. It does not upload objects
or require R2 credentials.

If the build used a custom workspace, use the same value when publishing:

```bash
BUILD_WORKSPACE=/build BUILD_ID=20260328.0 make publish-dry-run
```

## Publish

```bash
BUILD_ID=20260328.0 make publish
```

Immutable build keys are not overwritten unless `--allow-overwrite` is passed to
`scripts/publish-r2.sh`.

## Weekly Build, Then Publish

Build the weekly profile set without publishing:

```bash
IMAGE_PROFILES="generic-qemu digitalocean hetzner" make weekly-build
```

After the build succeeds, the command prints the exact publish commands for that
resolved `BUILD_ID`, for example:

```bash
BUILD_ID=20260514.0 make publish-dry-run
BUILD_ID=20260514.0 make publish
```

The combined build-and-publish wrapper is still available for automation:

```bash
IMAGE_PROFILES="generic-qemu digitalocean hetzner" make weekly-publish
```

Without an explicit `BUILD_ID`, the weekly wrappers ask R2 for the next build ID
using `scripts/next-build-id-r2.sh`. `make weekly-publish` checks required R2
publish configuration before starting the root build.

## Verification

After downloading a build directory's checksum files:

```bash
gpg --locate-keys packages@ph20.org
gpg --verify SHA256SUMS.asc SHA256SUMS
sha256sum -c SHA256SUMS
```

The public signing key reference is `https://ph20.org/keys/packages.asc`.
