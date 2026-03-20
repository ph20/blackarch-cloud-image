#!/usr/bin/env bash

set -o nounset
set -o errexit
set -o pipefail

readonly STRAP_URL="${BLACKARCH_STRAP_URL:-https://blackarch.org/strap.sh}"
WORKDIR="$(mktemp -d)"
readonly WORKDIR

function cleanup() {
  rm -rf "${WORKDIR}"
}
trap cleanup EXIT

curl -fsSL "${STRAP_URL}" -o "${WORKDIR}/strap.sh"

if [ -n "${BLACKARCH_STRAP_SHA256:-}" ]; then
  echo "${BLACKARCH_STRAP_SHA256}  ${WORKDIR}/strap.sh" | sha256sum --check --status -
fi

bash "${WORKDIR}/strap.sh"
