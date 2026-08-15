#!/usr/bin/env bash
# scripts/install-tools.sh
# Installs cosign, syft, and crane locally.
# Run once after cloning the repository.
set -euo pipefail

# Versions come from versions.env so a developer's local tools match what the
# workflows install. Three separate copies of these numbers is how the repo
# ended up reproducing a build with tools a version behind the pipeline's.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../../versions.env
source "${HERE}/versions.env"

BIN="${HOME}/.local/bin"
mkdir -p "${BIN}"

OS=$(uname -s | tr '[:upper:]' '[:lower:]')
ARCH=$(uname -m)
[[ "${ARCH}" == "x86_64" ]]  && ARCH="amd64"
[[ "${ARCH}" =~ ^(aarch64|arm64)$ ]] && ARCH="arm64"

echo "🔧 Installing tools for ${OS}/${ARCH} into ${BIN}"

# cosign
echo "  → cosign ${COSIGN_VERSION}"
curl -sSfLo "${BIN}/cosign" \
  "https://github.com/sigstore/cosign/releases/download/${COSIGN_VERSION}/cosign-${OS}-${ARCH}"
chmod +x "${BIN}/cosign"

# syft — from the pinned release archive, not by piping an installer script
# fetched from a mutable branch into a shell. That pattern is what this project
# exists to argue against, and it was in here.
echo "  → syft ${SYFT_VERSION}"
curl -sSfLo /tmp/syft.tar.gz \
  "https://github.com/anchore/syft/releases/download/${SYFT_VERSION}/syft_${SYFT_VERSION#v}_${OS}_${ARCH}.tar.gz"
tar -xzf /tmp/syft.tar.gz -C "${BIN}" syft
chmod +x "${BIN}/syft"
rm /tmp/syft.tar.gz

# crane (OCI registry inspection — the tool that answers "what is actually in
# the registry", which is the only way to settle a storage-location question)
#
# go-containerregistry does NOT use the same asset naming as cosign and syft:
# the OS is capitalised and the architecture is uname's, so it is
# `go-containerregistry_Linux_x86_64.tar.gz`, not `..._linux_amd64...`. This
# line used to build the lowercase/amd64 name, 404, and — because the curl had
# no -f — write the 404 page into the tarball, so the failure surfaced as
# "gzip: stdin: not in gzip format" and left the old crane in place. Every curl
# here now uses -f so a bad URL fails as a bad URL.
echo "  → crane ${CRANE_VERSION}"
CRANE_OS=$(uname -s)                       # Linux / Darwin, capitalised
CRANE_ARCH=$(uname -m)                     # x86_64 / arm64
curl -sSfLo /tmp/crane.tar.gz \
  "https://github.com/google/go-containerregistry/releases/download/${CRANE_VERSION}/go-containerregistry_${CRANE_OS}_${CRANE_ARCH}.tar.gz"
tar -xzf /tmp/crane.tar.gz -C "${BIN}" crane
chmod +x "${BIN}/crane"
rm /tmp/crane.tar.gz

echo ""
echo "✅ Done. Add to PATH if not already:"
echo "   export PATH=\"\${PATH}:${BIN}\""
