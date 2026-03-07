#!/usr/bin/env bash
# scripts/cosign-verify.sh
# Verifies the Cosign keyless signature of a container image.
# Checks the certificate was issued to the expected GitHub Actions identity.
#
# Cloud-agnostic: works identically for ECR and ACR images.
# Usage: scripts/cosign-verify.sh <IMAGE_REFERENCE>
set -euo pipefail

IMAGE="${1:?Usage: $0 <image-reference>}"
: "${COSIGN_CERTIFICATE_OIDC_ISSUER:?Set by env.aws}"
: "${COSIGN_CERTIFICATE_IDENTITY_REGEXP:?Set by env.aws}"

EXTRA="${COSIGN_EXTRA_FLAGS:-}"

echo "🔍 Verifying: ${IMAGE}"
echo "   Expected issuer  : ${COSIGN_CERTIFICATE_OIDC_ISSUER}"
echo "   Expected subject : ${COSIGN_CERTIFICATE_IDENTITY_REGEXP}"

cosign verify \
  --certificate-identity-regexp "${COSIGN_CERTIFICATE_IDENTITY_REGEXP}" \
  --certificate-oidc-issuer "${COSIGN_CERTIFICATE_OIDC_ISSUER}" \
  ${EXTRA} \
  "${IMAGE}" \
  | jq -r '.[0] | "   Signer: \(.optional.Issuer) / \(.optional.Subject)"'

echo "✅ Signature valid"
