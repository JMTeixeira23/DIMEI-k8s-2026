#!/usr/bin/env bash
# scripts/install-tools.sh
# Installs cosign, syft, and crane locally.
# Run once after cloning the repository.
set -euo pipefail

COSIGN_VERSION="v2.2.3"
SYFT_VERSION="v0.105.1"
CRANE_VERSION="v0.19.1"
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

# syft
echo "  → syft ${SYFT_VERSION}"
curl -sSfL https://raw.githubusercontent.com/anchore/syft/main/install.sh \
  | sh -s -- -b "${BIN}" "${SYFT_VERSION}"

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
