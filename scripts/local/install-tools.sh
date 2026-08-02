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
curl -sSLo "${BIN}/cosign" \
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

# crane (OCI registry inspection — useful for Phase 4 debugging)
echo "  → crane ${CRANE_VERSION}"
curl -sSLo /tmp/crane.tar.gz \
  "https://github.com/google/go-containerregistry/releases/download/${CRANE_VERSION}/go-containerregistry_${OS}_${ARCH}.tar.gz"
tar -xzf /tmp/crane.tar.gz -C "${BIN}" crane
chmod +x "${BIN}/crane"
rm /tmp/crane.tar.gz

echo ""
echo "✅ Done. Add to PATH if not already:"
echo "   export PATH=\"\${PATH}:${BIN}\""
