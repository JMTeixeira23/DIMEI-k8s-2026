#!/usr/bin/env bash
# scripts/smoke-test.sh
# Deploys an ephemeral pod to confirm the image pulls and runs successfully.
# Uses kubectl — cloud-agnostic once kubeconfig is set (scripts/kubeconfig.sh).
#
# Usage: scripts/smoke-test.sh <IMAGE_REFERENCE>
set -euo pipefail

IMAGE="${1:?Usage: $0 <image-reference>}"
POD="smoke-test-$(date +%s)"
TIMEOUT="90s"

echo "🚀 Deploying smoke-test pod: ${POD}"
echo "   Image  : ${IMAGE}"
echo "   Context: $(kubectl config current-context)"

kubectl run "${POD}" \
  --image="${IMAGE}" \
  --restart=Never \
  --command -- sh -c 'echo "=== Phase 1 smoke test PASSED ===" && date'

echo "⏳ Waiting for pod to complete (timeout: ${TIMEOUT})..."
kubectl wait --for=condition=Succeeded "pod/${POD}" --timeout="${TIMEOUT}"

echo ""
echo "📄 Pod output:"
kubectl logs "${POD}"

kubectl delete pod "${POD}" --ignore-not-found
echo ""
echo "✅ Smoke test passed for: ${IMAGE}"
