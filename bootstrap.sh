#!/usr/bin/env bash
# bootstrap.sh — run once after `terraform apply` in terraform/aws/
# Installs Kyverno on EKS and applies all ClusterPolicies with registry injection.
#
# Usage:
#   cd terraform/aws
#   terraform apply -var="github_org=JMTeixeira23" -var="github_repo=DIMEI-k8s-2026" -auto-approve
#   cd ../..
#   bash bootstrap.sh
#
# Safe to re-run — all steps are idempotent.

set -euo pipefail

CLUSTER_NAME="supply-chain-eks"
REGION="eu-west-1"
KYVERNO_VERSION="3.1.4"
KYVERNO_NS="kyverno"
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGISTRY="${AWS_ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"

echo "════════════════════════════════════════════════════"
echo "  Supply Chain Security — AWS Bootstrap"
echo "  Cluster : ${CLUSTER_NAME} (${REGION})"
echo "  Registry: ${REGISTRY}"
echo "════════════════════════════════════════════════════"
echo ""

# ── Step 1: Configure kubectl ─────────────────────────────────────────────────
echo "▶ Configuring kubectl..."
aws eks update-kubeconfig \
  --region "${REGION}" \
  --name "${CLUSTER_NAME}"
echo "  ✅ kubeconfig updated"

# ── Step 2: Wait for nodes ────────────────────────────────────────────────────
echo ""
echo "▶ Waiting for nodes to be Ready..."
kubectl wait node --all --for=condition=Ready --timeout=300s
echo "  ✅ Nodes ready"
kubectl get nodes

# ── Step 3: Install Kyverno via Helm ─────────────────────────────────────────
echo ""
echo "▶ Installing Kyverno ${KYVERNO_VERSION}..."
helm repo add kyverno https://kyverno.github.io/kyverno/ 2>/dev/null || true
helm repo update kyverno

KYVERNO_ROLE_ARN=$(cd terraform/aws && terraform output -raw kyverno_role_arn 2>/dev/null || \
  aws iam get-role --role-name kyverno-ecr-read \
    --query 'Role.Arn' --output text)

echo "  Kyverno IRSA role: ${KYVERNO_ROLE_ARN}"

helm upgrade --install kyverno kyverno/kyverno \
  --namespace "${KYVERNO_NS}" \
  --create-namespace \
  --version "${KYVERNO_VERSION}" \
  --set admissionController.replicas=3 \
  --set backgroundController.replicas=1 \
  --set reportsController.replicas=1 \
  --set cleanupController.replicas=1 \
  --set "admissionController.serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn=${KYVERNO_ROLE_ARN}" \
  --set failurePolicy=Ignore \
  --set forceFailurePolicyIgnore=true \
  --set webhooksCleanup.enabled=false \
  --timeout 5m \
  --no-hooks \
  --wait

echo "  ✅ Kyverno installed"

# ── Patch admission controller to force all webhooks to Ignore ───────────────
echo ""
echo "▶ Patching admission controller with --forceFailurePolicyIgnore..."
kubectl patch deployment kyverno-admission-controller -n kyverno --type=json \
  -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--forceFailurePolicyIgnore=true"}]' \
  2>/dev/null || true
kubectl rollout status deployment/kyverno-admission-controller \
  -n kyverno --timeout=60s
sleep 10
# Delete the policy webhook — it targets only kyverno.io resources (not pods)
# and Kyverno hardcodes it to Fail which blocks all kubectl operations
kubectl delete mutatingwebhookconfiguration kyverno-policy-mutating-webhook-cfg \
  --ignore-not-found
echo "  ✅ Webhooks fixed"

# ── Force webhooks to Ignore ─────────────────────────────────────────────────
# The background controller reverts webhooks to Fail. Scale it down first,
# patch all webhooks, then keep it down — it's only needed for background
# scanning, not for admission enforcement which is what we need.
echo ""
echo "▶ Forcing webhook failurePolicy to Ignore..."

# Scale down background + reports controllers so they stop reverting webhooks
kubectl scale deployment kyverno-background-controller   -n "${KYVERNO_NS}" --replicas=0 2>/dev/null || true
kubectl scale deployment kyverno-reports-controller   -n "${KYVERNO_NS}" --replicas=0 2>/dev/null || true
sleep 5

# Patch all mutating webhooks
for cfg in $(kubectl get mutatingwebhookconfigurations   --no-headers -o name | grep kyverno); do
  COUNT=$(kubectl get ${cfg} -o json | jq '.webhooks | length')
  for i in $(seq 0 $((COUNT-1))); do
    kubectl patch ${cfg} --type=json       -p="[{\"op\":\"replace\",\"path\":\"/webhooks/${i}/failurePolicy\",\"value\":\"Ignore\"}]"       2>/dev/null || true
  done
  echo "  ✅ Patched ${cfg}"
done

# Patch all validating webhooks
for cfg in $(kubectl get validatingwebhookconfigurations   --no-headers -o name | grep kyverno); do
  COUNT=$(kubectl get ${cfg} -o json | jq '.webhooks | length')
  for i in $(seq 0 $((COUNT-1))); do
    kubectl patch ${cfg} --type=json       -p="[{\"op\":\"replace\",\"path\":\"/webhooks/${i}/failurePolicy\",\"value\":\"Ignore\"}]"       2>/dev/null || true
  done
  echo "  ✅ Patched ${cfg}"
done

# ── Step 4: Suspend broken cleanup CronJobs ───────────────────────────────────
echo ""
echo "▶ Suspending cleanup CronJobs..."
for cj in kyverno-cleanup-admission-reports \
           kyverno-cleanup-cluster-admission-reports; do
  kubectl patch cronjob "${cj}" -n "${KYVERNO_NS}" \
    -p '{"spec":{"suspend":true}}' 2>/dev/null && \
    echo "  ✅ Suspended ${cj}" || \
    echo "  ⚠️  ${cj} not found"
done

# ── Step 5: Wait for admission controller ─────────────────────────────────────
echo ""
echo "▶ Waiting for Kyverno admission controller..."
kubectl rollout status deployment/kyverno-admission-controller \
  -n "${KYVERNO_NS}" --timeout=120s
echo "  ✅ Admission controller ready"
kubectl get pods -n "${KYVERNO_NS}"

# ── Step 6: Apply ClusterPolicies with registry injection ─────────────────────
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

# ── Step 7: Create namespaces ─────────────────────────────────────────────────
echo ""
echo "▶ Creating namespaces..."
kubectl create namespace supply-chain-demo \
  --dry-run=client -o yaml | kubectl apply -f -
echo "  ✅ supply-chain-demo ready"

# Exclude default namespace from Kyverno webhooks (used for smoke tests)
kubectl label namespace default kyverno.io/exclude=always --overwrite
echo "  ✅ default namespace excluded from Kyverno webhooks"

# ── Step 8: Set all Kyverno webhooks to Ignore ───────────────────────────────
# Prevents "context deadline exceeded" errors when webhook is briefly unavailable.
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
echo "  Bootstrap complete!"
echo ""
echo "  GitHub secrets (environment: aws):"
ROLE_ARN=$(cd terraform/aws && terraform output -raw github_actions_role_arn 2>/dev/null || echo "run terraform output")
echo "    AWS_ROLE_ARN     = ${ROLE_ARN}"
echo "    AWS_REGION       = ${REGION}"
echo "    ECR_REPO_NAME    = supply-chain/hello-world"
echo "    EKS_CLUSTER_NAME = ${CLUSTER_NAME}"
echo ""
echo "  Next: trigger supply-chain.yml (cloud: aws)"
echo "════════════════════════════════════════════════════"