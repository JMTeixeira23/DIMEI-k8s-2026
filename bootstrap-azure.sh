#!/usr/bin/env bash
# bootstrap-azure.sh — run once after `terraform apply` in terraform/azure/
# Installs Kyverno on AKS and applies all ClusterPolicies with registry injection.
#
# Usage:
#   cd terraform/azure
#   terraform apply -var="github_org=JMTeixeira23" -var="github_repo=DIMEI-k8s-2026" -var="location=northeurope" -auto-approve
#   cd ../..
#   bash bootstrap-azure.sh
#
# Safe to re-run — all steps are idempotent.

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

# ── Step 3: Get Terraform outputs ─────────────────────────────────────────────
echo ""
echo "▶ Reading Terraform outputs..."
KYVERNO_CLIENT_ID=$(cd terraform/azure && terraform output -raw kyverno_client_id)
TENANT_ID=$(cd terraform/azure && terraform output -raw tenant_id)
SUBSCRIPTION_ID=$(cd terraform/azure && terraform output -raw subscription_id)
GITHUB_CLIENT_ID=$(cd terraform/azure && terraform output -raw github_actions_client_id)
ACR_LOGIN_SERVER=$(cd terraform/azure && terraform output -raw acr_login_server)
REGISTRY="${ACR_LOGIN_SERVER}"

echo "  Kyverno client ID: ${KYVERNO_CLIENT_ID}"
echo "  Tenant ID:         ${TENANT_ID}"
echo "  Registry:          ${REGISTRY}"

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
echo "  ✅ Admission controller ready"
kubectl get pods -n "${KYVERNO_NS}"

# ── Step 7: Apply ClusterPolicies with registry injection ─────────────────────
# Policies use REGISTRY_PLACEHOLDER — inject actual registry URL via sed.
echo ""
echo "▶ Applying ClusterPolicies (Enforce mode, registry: ${REGISTRY})..."
mkdir -p /tmp/kyverno-rendered

for f in kyverno/verify-image-signature.yaml \
          kyverno/verify-sbom-cyclonedx.yaml \
          kyverno/verify-slsa-provenance.yaml; do
  sed "s|REGISTRY_PLACEHOLDER|${REGISTRY}|g" "${f}" \
    > "/tmp/kyverno-rendered/$(basename ${f})"
done

kubectl apply --server-side --force-conflicts -f /tmp/kyverno-rendered/

echo ""
echo "▶ Waiting for policies to be Ready..."
sleep 10
kubectl get clusterpolicies -o wide

# ── Step 8: Create namespaces ─────────────────────────────────────────────────
echo ""
echo "▶ Creating namespaces..."
kubectl create namespace supply-chain-demo \
  --dry-run=client -o yaml | kubectl apply -f -
echo "  ✅ supply-chain-demo ready"

# ── Step 9: Set all Kyverno webhooks to Ignore ───────────────────────────────
echo ""
echo "▶ Setting Kyverno webhooks to failurePolicy=Ignore..."
for wh in $(kubectl get mutatingwebhookconfigurations   --no-headers -o name | grep kyverno); do
  kubectl get "${wh}" -o json     | jq '.webhooks[].failurePolicy = "Ignore"'     | kubectl apply -f - 2>/dev/null || true
  echo "  ✅ Patched ${wh}"
done
for wh in $(kubectl get validatingwebhookconfigurations   --no-headers -o name | grep kyverno); do
  kubectl get "${wh}" -o json     | jq '.webhooks[].failurePolicy = "Ignore"'     | kubectl apply -f - 2>/dev/null || true
  echo "  ✅ Patched ${wh}"
done

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════════════════"
echo "  Azure Bootstrap complete!"
echo ""
echo "  Update GitHub secrets (environment: azure):"
echo "    AZURE_CLIENT_ID       = ${GITHUB_CLIENT_ID}"
echo "    AZURE_TENANT_ID       = ${TENANT_ID}"
echo "    AZURE_SUBSCRIPTION_ID = ${SUBSCRIPTION_ID}"
echo "    ACR_LOGIN_SERVER      = ${ACR_LOGIN_SERVER}"
echo "    ACR_REPO_NAME         = supply-chain/hello-world"
echo "    AKS_CLUSTER_NAME      = ${CLUSTER_NAME}"
echo "    AKS_RESOURCE_GROUP    = ${RESOURCE_GROUP}"
echo ""
echo "  Next: trigger supply-chain.yml (cloud: azure)"
echo "════════════════════════════════════════════════════"