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
- `awk`

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

Both image and rootfs logs are sanitized before upload, including during dry
runs. Local checkout and profile-script directory prefixes are replaced with
markers such as `[repo]` and `[profile-hooks]`. Separate build workspace paths
such as `/build/output` and `/build/tmp` remain visible. Paths inside the
checkout are masked even when the checkout is also the build workspace.
Commands, script names, artifact names, and paths inside the guest image remain
readable. The publisher also reads the script locations from older logs
so publishing from a different checkout does not expose their original paths.
Original logs are kept locally; temporary sanitized copies are removed when
the publisher exits. Existing builds do not need to be rebuilt for this change.

Previously uploaded logs are not changed automatically. Replacing an existing
published log requires an explicit targeted upload to its R2 object key.

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

## Pruning Old Weekly Builds

Pruning is a separate operation; publishing never deletes old builds.
`scripts/prune-r2.sh` reads the published R2 catalog and defaults to a dry run:

```bash
./scripts/prune-r2.sh
./scripts/prune-r2.sh --channel weekly --keep-last 8 --dry-run
```

The default policy keeps the newest 4 weekly builds, ordered by build ID with
numeric iteration ordering (`YYYYMMDD.10` is newer than `YYYYMMDD.9`). The build
referenced by `blackarch/images/latest.json` is always protected, even if that
means keeping an additional older weekly build. The `releases` channel cannot
be pruned. Unindexed/incomplete uploads are not selected.

The plan lists every exact object key and the object count and bytes for each
selected build. Deletion includes all objects under that build's exact
`blackarch/images/weekly/<year>/<build_id>/` prefix: images, checksums,
signatures, manifests, logs, and the per-build index. The shared catalog at
`blackarch/images/index.json` is updated after each fully deleted build.
`latest.json`, release objects, and local build outputs are left in place.

Apply a reviewed policy explicitly:

```bash
./scripts/prune-r2.sh --keep-last 8 --apply
```

Run the script directly. Every invocation reads a fresh catalog and generates
a new plan. Dry runs require the same R2 configuration and valid credentials as
real publishing because they list actual remote objects. The credentials need read
and list permissions; applying also needs object deletion and root index write
permissions. Use an AWS CLI supporting `s3api put-object --if-match`.

Run pruning only while publishing and other pruning processes are idle. The
script checks catalog/latest ETags before changes and conditionally writes the
catalog so a concurrent catalog update is not silently overwritten. These
checks do not make object deletion and publishing one atomic operation.

Successful quiet-mode bulk deletion can produce empty AWS CLI output; this is
accepted when the command succeeds. Explicit per-object errors, invalid JSON,
and nonzero command exit statuses still stop pruning.

On a failed deletion, the affected build's catalog entry remains available for
a retry; earlier completed removals remain committed. If an index write fails
after deletion, that entry can temporarily reference removed objects. Stop the
conflicting operation or fix the reported error, review a fresh dry run, then
rerun with `--apply` to remove remaining objects and reconcile the entry.
Authentication, metadata, and listing errors stop pruning rather than being
treated as an empty bucket. No lifecycle rules are changed.

## Verification

After downloading a build directory's checksum files:

```bash
gpg --locate-keys packages@ph20.org
gpg --verify SHA256SUMS.asc SHA256SUMS
sha256sum -c SHA256SUMS
```

The public signing key reference is `https://ph20.org/keys/packages.asc`.
