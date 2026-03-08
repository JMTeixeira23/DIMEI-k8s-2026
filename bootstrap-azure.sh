#!/usr/bin/env bash
# bootstrap-azure.sh — run once after `terraform apply` in terraform/azure/
# Installs Kyverno on AKS and applies all Phase 6 ClusterPolicies.
#
# Prerequisites:
#   az login (or service principal env vars set)
#   terraform/azure/ applied successfully
#
# Usage:
#   cd terraform/azure
#   terraform apply -var="github_org=JMTeixeira23" -var="github_repo=DIMEI-k8s-2026" -auto-approve
#   cd ../..
#   bash bootstrap-azure.sh

set -euo pipefail

RESOURCE_GROUP="supply-chain-rg"
CLUSTER_NAME="supply-chain-aks"
KYVERNO_VERSION="3.1.4"
KYVERNO_NS="kyverno"

echo "════════════════════════════════════════════════════"
echo "  Supply Chain Security — Azure Bootstrap"
echo "  Cluster: ${CLUSTER_NAME} (${RESOURCE_GROUP})"
echo "════════════════════════════════════════════════════"
echo ""

# ── Step 1: Get kubeconfig ────────────────────────────────────────────────────
echo "▶ Configuring kubectl for AKS..."
az aks get-credentials \
  --resource-group "${RESOURCE_GROUP}" \
  --name "${CLUSTER_NAME}" \
  --overwrite-existing
echo "  ✅ kubeconfig updated"

# ── Step 2: Wait for nodes ────────────────────────────────────────────────────
echo ""
echo "▶ Waiting for nodes to be Ready..."
kubectl wait node --all --for=condition=Ready --timeout=300s
kubectl get nodes

# ── Step 3: Get Kyverno workload identity client ID from Terraform output ─────
echo ""
echo "▶ Getting Kyverno workload identity client ID..."
KYVERNO_CLIENT_ID=$(cd terraform/azure && \
  terraform output -raw kyverno_client_id 2>/dev/null)
TENANT_ID=$(cd terraform/azure && \
  terraform output -raw tenant_id 2>/dev/null)

echo "  Kyverno client ID: ${KYVERNO_CLIENT_ID}"
echo "  Tenant ID:         ${TENANT_ID}"

# ── Step 4: Install Kyverno via Helm ─────────────────────────────────────────
echo ""
echo "▶ Installing Kyverno ${KYVERNO_VERSION}..."
helm repo add kyverno https://kyverno.github.io/kyverno/ 2>/dev/null || true
helm repo update kyverno

helm upgrade --install kyverno kyverno/kyverno \
  --namespace "${KYVERNO_NS}" \
  --create-namespace \
  --version "${KYVERNO_VERSION}" \
  --set admissionController.replicas=3 \
  --set backgroundController.replicas=1 \
  --set reportsController.replicas=1 \
  --set cleanupController.replicas=1 \
  --set failurePolicy=Ignore \
  --set webhooksCleanup.enabled=false \
  --set "admissionController.serviceAccount.annotations.azure\\.workload\\.identity/client-id=${KYVERNO_CLIENT_ID}" \
  --set-string "admissionController.podLabels.azure\\.workload\\.identity/use=true" \
  --timeout 5m \
  --no-hooks \
  --wait

echo "  ✅ Kyverno installed"

# ── Step 5: Suspend broken cleanup CronJobs ───────────────────────────────────
echo ""
echo "▶ Suspending cleanup CronJobs..."
for cj in kyverno-cleanup-admission-reports \
           kyverno-cleanup-cluster-admission-reports; do
  kubectl patch cronjob "${cj}" -n "${KYVERNO_NS}" \
    -p '{"spec":{"suspend":true}}' 2>/dev/null && \
    echo "  ✅ Suspended ${cj}" || \
    echo "  ⚠️  ${cj} not found"
done

# ── Step 6: Wait for admission controller ─────────────────────────────────────
echo ""
echo "▶ Waiting for Kyverno admission controller..."
kubectl rollout status deployment/kyverno-admission-controller \
  -n "${KYVERNO_NS}" --timeout=120s
kubectl get pods -n "${KYVERNO_NS}"

# ── Step 7: Apply Phase 6 ClusterPolicies ────────────────────────────────────
echo ""
echo "▶ Applying Phase 6 ClusterPolicies (Enforce mode)..."
kubectl apply --server-side --force-conflicts \
  -f kyverno/azure/verify-image-signature.yaml
kubectl apply --server-side --force-conflicts \
  -f kyverno/azure/verify-sbom-cyclonedx.yaml
kubectl apply --server-side --force-conflicts \
  -f kyverno/azure/verify-slsa-provenance.yaml

sleep 10
kubectl get clusterpolicies -o wide

# ── Step 8: Create namespaces ─────────────────────────────────────────────────
echo ""
echo "▶ Creating namespaces..."
kubectl create namespace supply-chain-demo --dry-run=client -o yaml \
  | kubectl apply -f -

echo ""
echo "════════════════════════════════════════════════════"
echo "  Azure Bootstrap complete!"
echo ""
echo "  Add these secrets to GitHub (environment: azure):"
echo "    AZURE_CLIENT_ID      = ${KYVERNO_CLIENT_ID}"
echo "    AZURE_TENANT_ID      = ${TENANT_ID}"
echo "    AZURE_SUBSCRIPTION_ID = (from terraform output)"
echo "    ACR_LOGIN_SERVER     = (from terraform output)"
echo "    ACR_REPO_NAME        = supply-chain/hello-world"
echo "    AKS_CLUSTER_NAME     = ${CLUSTER_NAME}"
echo "    AKS_RESOURCE_GROUP   = ${RESOURCE_GROUP}"
echo ""
echo "  Then trigger: phase1-azure.yml → phase2-azure.yml → phase3-azure.yml"
echo "════════════════════════════════════════════════════"