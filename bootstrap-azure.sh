#!/usr/bin/env bash
# bootstrap-azure.sh — run once after `terraform apply` in infrastructure/azure/
# Installs Kyverno on AKS and applies all ClusterPolicies with registry injection.
#
# Usage:
#   cd infrastructure/azure
#   terraform apply -var="github_org=JMTeixeira23" -var="github_repo=DIMEI-k8s-2026" -var="location=swedencentral" -auto-approve
#   cd ../..
#   bash bootstrap-azure.sh
#
# Safe to re-run — all steps are idempotent.

set -euo pipefail

RESOURCE_GROUP="supply-chain-rg"
CLUSTER_NAME="supply-chain-aks"
KYVERNO_NS="kyverno"

# ── Versions ─────────────────────────────────────────────────────────────────
# Shared with bootstrap-aws.sh so the two clouds cannot end up on different
# Kyverno versions. That is not a tidiness point: the whole two-cloud comparison
# rests on the clusters being the same in every respect but the provider.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=versions.env
source "${HERE}/versions.env"
KYVERNO_VERSION="${KYVERNO_VERSION:-${KYVERNO_CHART_VERSION}}"

if [ "${KYVERNO_VERSION}" != "${RESULTS_KYVERNO_CHART}" ]; then
  cat >&2 <<DRIFT

  ╔════════════════════════════════════════════════════════════════════════╗
  ║  results/ DOES NOT DESCRIBE THE CLUSTER THIS IS ABOUT TO BUILD         ║
  ╚════════════════════════════════════════════════════════════════════════╝

    installing : Kyverno chart ${KYVERNO_VERSION} (app ${KYVERNO_APP_VERSION})
    results/   : Kyverno chart ${RESULTS_KYVERNO_CHART} (app ${RESULTS_KYVERNO_APP})

  The AWS cluster must be rebuilt on the same version before the two are
  compared. A comparison across two Kyverno versions measures the versions, not
  the cloud providers, and is worse than reporting one cloud honestly.

DRIFT
  sleep 3
fi

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
KYVERNO_CLIENT_ID=$(cd infrastructure/azure && terraform output -raw kyverno_client_id)
TENANT_ID=$(cd infrastructure/azure && terraform output -raw tenant_id)
SUBSCRIPTION_ID=$(cd infrastructure/azure && terraform output -raw subscription_id)
GITHUB_CLIENT_ID=$(cd infrastructure/azure && terraform output -raw github_actions_client_id)
ACR_LOGIN_SERVER=$(cd infrastructure/azure && terraform output -raw acr_login_server)
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
  --values helm/kyverno-values.yaml \
  --namespace "${KYVERNO_NS}" \
  --create-namespace \
  --version "${KYVERNO_VERSION}" \
  --set admissionController.replicas=3 \
  --set backgroundController.replicas=1 \
  --set reportsController.replicas=1 \
  --set cleanupController.replicas=1 \
  --set webhooksCleanup.enabled=false \
  --set "admissionController.rbac.serviceAccount.annotations.azure\\.workload\\.identity/client-id=${KYVERNO_CLIENT_ID}" \
  --set-string "admissionController.podLabels.azure\\.workload\\.identity/use=true" \
  --timeout 5m \
  --no-hooks \
  --wait

echo "  ✅ Kyverno installed"

# ── Workload identity: the same defect as AWS, and never masked here ─────────
#
# Defect D30. The client-id annotation used to be set on
# `admissionController.serviceAccount.annotations`, a value this chart does not
# define — the template reads `admissionController.rbac.serviceAccount.annotations`.
# Helm ignored it in silence on chart 3.1.4 and 3.8.2 alike (verified by
# rendering both). The podLabels line beside it was always correct, which is
# what made the mistake so easy to miss: half the wiring worked.
#
# Unlike bootstrap-aws.sh this script never had a `kubectl annotate` fallback,
# so Kyverno on AKS has never held a workload identity. No Azure result has been
# collected in this cycle, so nothing published is affected — but the first ACR
# image verification would have failed exactly as AWS did on 2026-08-15.
echo ""
echo "▶ Verifying Kyverno received the workload identity..."
if kubectl get sa kyverno-admission-controller -n "${KYVERNO_NS}" \
     -o jsonpath='{.metadata.annotations.azure\.workload\.identity/client-id}' \
     2>/dev/null | grep -q .; then
  echo "  ✅ client-id annotation present on the service account"
else
  echo ""
  echo "  ❌ The Kyverno service account has no azure.workload.identity/client-id."
  echo "     Every ACR image verification will hang and be cancelled at the 10 s"
  echo "     webhook deadline. This is defect D30 — do not run the experiments"
  echo "     against this cluster."
  echo "       kubectl get sa kyverno-admission-controller -n ${KYVERNO_NS} -o yaml"
  exit 5
fi

# The projected token is mounted at pod admission, so pods that started before
# the annotation existed keep running without it.
if ! kubectl get pods -n "${KYVERNO_NS}" \
       -l app.kubernetes.io/component=admission-controller \
       -o jsonpath='{range .items[*]}{.spec.containers[0].env[?(@.name=="AZURE_FEDERATED_TOKEN_FILE")].name}{"\n"}{end}' \
       2>/dev/null | grep -q AZURE_FEDERATED_TOKEN_FILE; then
  echo "  ⚠️  Pods are running without the federated token. Restarting..."
  kubectl rollout restart deployment/kyverno-admission-controller -n "${KYVERNO_NS}"
  kubectl rollout status  deployment/kyverno-admission-controller -n "${KYVERNO_NS}" --timeout=5m
fi

# ── ACR role assignments must exist in Azure, not merely in terraform state ──
#
# Defect D39. A `terraform destroy` followed by `apply` recreates the registry
# with the *same* resource ID (same name, resource group and subscription).
# Azure's RBAC garbage collector, processing the deletion of the old resource at
# that scope, then removes the role assignments the apply had just created.
# Terraform records them as created and never notices; `terraform plan` only
# reports the drift on a later refresh.
#
# All three assignments scoped to the ACR were lost this way on 2026-08-15:
#   AcrPush  for the GitHub Actions service principal  -> pipeline cannot push
#   AcrPull  for the AKS kubelet identity              -> pods cannot pull
#   AcrPull  for the Kyverno workload identity         -> signature verification
#                                                         fails, and it looks
#                                                         like a policy failure
#
# The last one is why this check exists rather than leaving the pipeline to fail:
# a missing AcrPull on Kyverno produces denials that read like a broken policy,
# which is the most expensive kind of wrong answer for this thesis to collect.
echo ""
echo "▶ Verifying the ACR role assignments exist in Azure..."
# Derived from REGISTRY (set above from ACR_LOGIN_SERVER) so this follows
# whatever registry the deployment actually uses, rather than a hardcoded name.
ACR_NAME="${REGISTRY%%.azurecr.io}"
ACR_ID=$(az acr show -n "${ACR_NAME}" -g "${RESOURCE_GROUP}" \
         --query id -o tsv 2>/dev/null || true)

if [ -z "${ACR_ID}" ]; then
  echo "  ⚠️  Could not resolve the ACR '${ACR_NAME}' — skipping the RBAC check."
  echo "     (Not fatal here; the pipeline will surface it.)"
else
  ACR_ROLES=$(az role assignment list --scope "${ACR_ID}" \
              --query "[].roleDefinitionName" -o tsv 2>/dev/null | sort -u | tr '\n' ' ')
  MISSING=""
  printf '%s' "${ACR_ROLES}" | grep -q 'AcrPush' || MISSING="${MISSING} AcrPush"
  printf '%s' "${ACR_ROLES}" | grep -q 'AcrPull' || MISSING="${MISSING} AcrPull"

  if [ -n "${MISSING}" ]; then
    echo ""
    echo "  ❌ Missing role assignment(s) on ${ACR_NAME}:${MISSING}"
    echo "     Found at that scope: ${ACR_ROLES:-none}"
    echo ""
    echo "     This is defect D39 — terraform state claims these exist. Re-run"
    echo "     apply from infrastructure/azure/ to recreate them, then re-run"
    echo "     this script. Do NOT run the experiments against this cluster:"
    echo "     a missing AcrPull on Kyverno is indistinguishable from a policy"
    echo "     that legitimately denied the image."
    echo "       terraform apply -var=\"github_org=...\" -var=\"github_repo=...\" \\"
    echo "         -var=\"location=swedencentral\""
    exit 6
  fi
  echo "  ✅ ACR role assignments present: ${ACR_ROLES}"
fi

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

# ── Scale down the background and reports controllers ────────────────────────
# Neither participates in admission. The admission controller is what registers
# and owns the webhook configurations; these two do background scanning and
# report generation, which this evaluation does not use and which produce churn
# in the metrics the latency experiment reads.
#
# This block used to also patch every Kyverno webhook to failurePolicy=Ignore,
# on the belief that the background controller was reverting them to Fail. It
# was not — Kyverno's admission controller writes those objects, and it writes
# Ignore because features.forceFailurePolicyIgnore.enabled is true in
# helm/kyverno-values.yaml. The patch loop fought whatever Kyverno wrote next,
# gave kubectl-patch ownership of a field Helm also manages, and would have
# silently reverted the fail-closed experiment to fail-open before it ran.
# The failure policy now has exactly one control point: that Helm value, driven
# by scripts/set-failure-policy.sh.
echo ""
echo "▶ Scaling down background and reports controllers..."
kubectl scale deployment kyverno-background-controller \
  -n "${KYVERNO_NS}" --replicas=0 2>/dev/null || true
kubectl scale deployment kyverno-reports-controller \
  -n "${KYVERNO_NS}" --replicas=0 2>/dev/null || true
sleep 5
echo "  ✅ background and reports controllers scaled to 0"

# ── Step 5: Remove leftovers from the cleanup CronJobs ───────────────────────
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

# ── Step 6: Wait for admission controller ─────────────────────────────────────
echo ""
echo "▶ Waiting for Kyverno admission controller..."
kubectl rollout status deployment/kyverno-admission-controller \
  -n "${KYVERNO_NS}" --timeout=300s
echo "  ✅ Admission controller ready"
kubectl get pods -n "${KYVERNO_NS}"

# ── Step 7: Apply ClusterPolicies with registry injection ─────────────────────
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

# ── Step 8: Create namespaces ─────────────────────────────────────────────────
echo ""
echo "▶ Creating namespaces..."
kubectl create namespace supply-chain-demo \
  --dry-run=client -o yaml | kubectl apply -f -
echo "  ✅ supply-chain-demo ready"

# Exclude default namespace from Kyverno webhooks (used for smoke tests)
kubectl label namespace default kyverno.io/exclude=always --overwrite
echo "  ✅ default namespace excluded from Kyverno webhooks"

# ── Verify the admission failure policy ──────────────────────────────────────
# Read back rather than patched. The value comes from
# features.forceFailurePolicyIgnore.enabled in helm/kyverno-values.yaml; this
# step exists so the bootstrap fails loudly if the cluster does not agree with
# the file, instead of forcing agreement and hiding a drift.
#
# To switch between fail-open and fail-closed, do not edit this block:
#   bash scripts/set-failure-policy.sh fail
#   bash scripts/set-failure-policy.sh ignore
echo ""
echo "▶ Verifying admission failure policy..."
POD_WEBHOOKS=$(kubectl get validatingwebhookconfigurations,mutatingwebhookconfigurations \
  -o json 2>/dev/null \
  | jq -r '[ .items[]
             | select(.metadata.name | test("kyverno"))
             | .webhooks[]?
             | select(any(.rules[]?;
                 (.resources[]? == "pods") or (.resources[]? == "*")))
             | "\(.name)=\(.failurePolicy)" ] | unique | join(" ")' \
  2>/dev/null || true)
echo "  Pod-intercepting webhooks: ${POD_WEBHOOKS:-<none>}"
if [ -z "${POD_WEBHOOKS}" ]; then
  echo "  ⚠️  no Pod-intercepting Kyverno webhook found — policies may not be applied yet"
else
  echo "  ✅ failure policy read from the cluster, not imposed on it"
fi

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
echo "  Next: trigger supply-chain-pipeline.yml (cloud: azure)"
echo "════════════════════════════════════════════════════"