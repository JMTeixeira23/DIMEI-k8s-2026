#!/usr/bin/env bash
# scripts/cosign-sign.sh
# Signs a container image with Cosign keyless signing.
#
# Cloud-agnostic: Cosign signs via the Sigstore transparency log using the
# GitHub Actions OIDC token regardless of whether the image is in ECR or ACR.
# The only cloud-specific difference (ACR referrers mode) is handled via
# COSIGN_EXTRA_FLAGS when needed.
#
# Usage:
#   scripts/cosign-sign.sh <IMAGE_REFERENCE>
#   COSIGN_EXTRA_FLAGS="--registry-referrers-mode=oci-1-1" scripts/cosign-sign.sh <IMG>
#
# Required env vars (set by env.aws / env.azure):
#   COSIGN_CERTIFICATE_OIDC_ISSUER
set -euo pipefail

IMAGE="${1:?Usage: $0 <image-reference>}"
: "${COSIGN_CERTIFICATE_OIDC_ISSUER:?Set by env.aws}"

EXTRA="${COSIGN_EXTRA_FLAGS:-}"

echo "🔏 Signing: ${IMAGE}"
echo "   OIDC issuer : ${COSIGN_CERTIFICATE_OIDC_ISSUER}"

# --yes skips the interactive confirmation prompt in CI and local use
cosign sign --yes ${EXTRA} "${IMAGE}"
echo "✅ Signed"

echo ""
echo "📋 Registry artefact tree:"
cosign tree "${IMAGE}"
