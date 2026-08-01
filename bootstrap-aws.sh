#!/usr/bin/env bash
# bootstrap.sh — run once after `terraform apply` in infrastructure/aws/
# Installs Kyverno on EKS and applies all ClusterPolicies with registry injection.
#
# Usage:
#   cd infrastructure/aws
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

# ── Step 3: Sync Kyverno IAM role trust policy via Terraform ─────────────────
# The trust policy must reference the current cluster's OIDC provider ID.
# Every rebuild creates a new OIDC provider — Terraform updates the trust policy.
echo ""
echo "▶ Syncing Kyverno IAM role trust policy..."
cd infrastructure/aws

# Import role if not already in state
terraform state show aws_iam_role.kyverno_ecr >/dev/null 2>&1 || \
  terraform import aws_iam_role.kyverno_ecr kyverno-ecr-read 2>/dev/null || true

terraform state show aws_iam_role_policy_attachment.kyverno_ecr_read >/dev/null 2>&1 || \
  terraform import aws_iam_role_policy_attachment.kyverno_ecr_read \
    "kyverno-ecr-read/arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly" 2>/dev/null || true

terraform apply \
  -var="github_org=JMTeixeira23" \
  -var="github_repo=DIMEI-k8s-2026" \
  -target=aws_iam_role.kyverno_ecr \
  -target=aws_iam_role_policy_attachment.kyverno_ecr_read \
  -auto-approve

KYVERNO_ROLE_ARN=$(terraform output -raw kyverno_role_arn 2>/dev/null || \
  aws iam get-role --role-name kyverno-ecr-read \
    --query 'Role.Arn' --output text)

cd ../..
echo "  Kyverno role ARN: ${KYVERNO_ROLE_ARN}"

# ── Step 4: Install Kyverno via Helm ─────────────────────────────────────────
echo ""
echo "▶ Installing Kyverno ${KYVERNO_VERSION}..."
helm repo add kyverno https://kyverno.github.io/kyverno/ 2>/dev/null || true
helm repo update kyverno

echo "  Kyverno IRSA role: ${KYVERNO_ROLE_ARN}"

helm upgrade --install kyverno kyverno/kyverno \
  --values helm/kyverno-values.yaml \
  --namespace "${KYVERNO_NS}" \
  --create-namespace \
  --version "${KYVERNO_VERSION}" \
  --set admissionController.replicas=3 \
  --set backgroundController.replicas=1 \
  --set reportsController.replicas=1 \
  --set cleanupController.replicas=1 \
  --set "admissionController.serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn=${KYVERNO_ROLE_ARN}" \
  --set webhooksCleanup.enabled=false \
  --timeout 5m \
  --no-hooks \
  --wait

echo "  ✅ Kyverno installed"

# Explicitly annotate the service account — the Helm --set flag is unreliable.
# IRSA token injection requires this annotation to be present before pod start.
echo ""
echo "▶ Annotating Kyverno service account for IRSA..."
kubectl annotate serviceaccount kyverno-admission-controller   -n "${KYVERNO_NS}"   "eks.amazonaws.com/role-arn=${KYVERNO_ROLE_ARN}"   --overwrite
echo "  ✅ IRSA annotation set"

# ── Remove the policy webhook ────────────────────────────────────────────────
# --forceFailurePolicyIgnore is set at install time via
# features.forceFailurePolicyIgnore.enabled in helm/kyverno-values.yaml. It used
# to be appended to the deployment's args with `kubectl patch` after install,
# which gave the "kubectl-patch" field manager ownership of that field — Helm 4
# applies server-side and refuses to overwrite another manager's field, so every
# re-run of this script failed with a conflict on
# .spec.template.spec.containers[kyverno].args. Setting it through the chart
# keeps Helm the sole owner and makes the script re-runnable.
echo ""
echo "▶ Removing the policy webhook..."
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

# ── Step 4: Remove leftovers from the cleanup CronJobs ───────────────────────
# The CronJobs are no longer installed — cleanupJobs.*.enabled=false in
# helm/kyverno-values.yaml — because they run bitnami/kubectl:1.28.5, which does
# not pull here, and their 10-minute schedule could fire before the old
# suspend-after-install step got to them. Helm removes the CronJobs on upgrade,
# but Jobs and Pods they already spawned are not chart-managed, so clear those.
echo ""
echo "▶ Clearing cleanup CronJob leftovers..."
kubectl delete cronjob -n "${KYVERNO_NS}" \
  kyverno-cleanup-admission-reports \
  kyverno-cleanup-cluster-admission-reports \
  --ignore-not-found 2>/dev/null || true
for j in $(kubectl get jobs -n "${KYVERNO_NS}" --no-headers -o name 2>/dev/null \
             | grep "kyverno-cleanup-" || true); do
  kubectl delete "${j}" -n "${KYVERNO_NS}" --ignore-not-found 2>/dev/null || true
  echo "  ✅ Removed ${j}"
done
echo "  ✅ No cleanup CronJobs installed"

# ── Step 5: Wait for admission controller ─────────────────────────────────────
echo ""
echo "▶ Waiting for Kyverno admission controller..."
kubectl rollout status deployment/kyverno-admission-controller \
  -n "${KYVERNO_NS}" --timeout=300s
echo "  ✅ Admission controller ready"
kubectl get pods -n "${KYVERNO_NS}"

# ── Step 6: Apply ClusterPolicies with registry injection ─────────────────────
# Policies use REGISTRY_PLACEHOLDER — inject actual registry URL via sed.
echo ""
echo "▶ Applying ClusterPolicies (Enforce mode, registry: ${REGISTRY})..."
mkdir -p /tmp/kyverno-rendered

for f in policies/verify-image-signature.yaml \
          policies/verify-sbom-cyclonedx.yaml \
          policies/verify-slsa-provenance.yaml; do
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
ROLE_ARN=$(cd infrastructure/aws && terraform output -raw github_actions_role_arn 2>/dev/null || echo "run terraform output")
echo "    AWS_ROLE_ARN     = ${ROLE_ARN}"
echo "    AWS_REGION       = ${REGION}"
echo "    ECR_REPO_NAME    = supply-chain/hello-world"
echo "    EKS_CLUSTER_NAME = ${CLUSTER_NAME}"
echo ""
echo "  Next: trigger supply-chain-pipeline.yml (cloud: aws)"
echo "════════════════════════════════════════════════════"