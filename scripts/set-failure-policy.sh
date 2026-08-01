#!/usr/bin/env bash
# scripts/set-failure-policy.sh <ignore|fail>
#
# Switches the cluster between the two admission-failure configurations that
# revision item 1.3 asks to be reported side by side:
#
#   ignore  fail-open   — if Kyverno cannot be reached, the pod is admitted
#                         *without* being verified. Availability is preserved,
#                         the control is not.
#   fail    fail-closed — if Kyverno cannot be reached, the pod is rejected.
#                         The control holds, at the cost of pod creation in
#                         every matched namespace.
#
# HOW IT WORKS, AND WHY IT IS NOT A `kubectl patch`
#
# Kyverno generates its webhook configurations at runtime; they are not rendered
# by the chart. It creates *paired* webhooks — `…svc-ignore` and `…svc-fail` —
# and routes each policy's rules to whichever matches that policy's effective
# failure policy. The controller feature flag `forceFailurePolicyIgnore` forces
# every rule onto the `-ignore` side. Turning it off lets each ClusterPolicy's
# own `failurePolicy` apply, which defaults to `Fail`.
#
# So the flag is the entire control surface, and this script is a Helm upgrade
# plus a verification loop. The repository used to patch the live
# WebhookConfiguration objects instead — in `bootstrap-aws.sh` twice, in
# `bootstrap-azure.sh` twice and in `supply-chain-pipeline.yml` once. That was
# removed for three reasons: it fought whatever Kyverno wrote next, it gave
# `kubectl-patch` ownership of a field Helm also manages (the field-manager
# conflict that broke every bootstrap re-run), and it would have silently
# reverted this experiment to fail-open before the measurement began.
#
# VERIFICATION
#
# The script does not trust the upgrade. It reads back every Kyverno webhook
# that would intercept a Pod create and requires all of them to report the
# requested failure policy before exiting successfully. The observed state is
# written to ${RESULTS_DIR}/_failure_policy.json so that any evidence artefact
# produced afterwards carries the configuration it was produced under.
#
# There is a second, independent confirmation available for free: the webhook
# name appears in every Kyverno denial message. Under fail-open the artefacts
# record `validate.kyverno.svc-ignore`; under fail-closed the same denials must
# read `…-fail`. If a fail-closed evidence run still quotes `-ignore`, the
# configuration did not take effect regardless of what this script reported.
#
# Usage:
#   bash scripts/set-failure-policy.sh fail
#   RESULTS_DIR=/tmp/x bash scripts/set-failure-policy.sh ignore
set -euo pipefail

MODE="${1:-}"
KYVERNO_NS="${KYVERNO_NS:-kyverno}"
KYVERNO_RELEASE="${KYVERNO_RELEASE:-kyverno}"
KYVERNO_VERSION="${KYVERNO_VERSION:-3.1.4}"
RESULTS_DIR="${RESULTS_DIR:-/tmp/failure-policy}"
SETTLE_SECONDS="${SETTLE_SECONDS:-20}"

case "${MODE}" in
  ignore) FORCE_IGNORE=true  ; WANT=Ignore ;;
  fail)   FORCE_IGNORE=false ; WANT=Fail   ;;
  *)
    echo "usage: $0 <ignore|fail>" >&2
    exit 2
    ;;
esac

mkdir -p "${RESULTS_DIR}"

# Every Kyverno webhook that would intercept a Pod create, as "name=failurePolicy".
# Selecting on the rules rather than on the webhook name means a renamed or
# additional webhook is still caught: what matters is which ones see the request.
pod_webhooks() {
  kubectl get validatingwebhookconfigurations,mutatingwebhookconfigurations \
    -o json 2>/dev/null \
  | jq -r '
      [ .items[]
        | select(.metadata.name | test("kyverno"))
        | .webhooks[]?
        | select(any(.rules[]?;
            (.resources[]? == "pods") or (.resources[]? == "*")))
        | "\(.name)=\(.failurePolicy)" ]
      | unique | join(" ")' 2>/dev/null || true
}

echo "════════════════════════════════════════════════════════════"
echo "  Admission failure policy → ${WANT}  (${MODE})"
echo "  forceFailurePolicyIgnore.enabled = ${FORCE_IGNORE}"
echo "════════════════════════════════════════════════════════════"
echo "  before: $(pod_webhooks)"

helm repo add kyverno https://kyverno.github.io/kyverno/ >/dev/null 2>&1 || true
helm repo update kyverno >/dev/null 2>&1 || true

# --reuse-values keeps everything the bootstrap set, including the cloud-specific
# IRSA / workload-identity wiring that is passed as --set at install time and is
# not in the values file. Only the one flag changes.
helm upgrade "${KYVERNO_RELEASE}" kyverno/kyverno \
  --namespace "${KYVERNO_NS}" \
  --version "${KYVERNO_VERSION}" \
  --reuse-values \
  --set "features.forceFailurePolicyIgnore.enabled=${FORCE_IGNORE}" \
  --timeout 5m \
  --no-hooks \
  --wait

kubectl rollout status deployment/kyverno-admission-controller \
  -n "${KYVERNO_NS}" --timeout=300s

# Kyverno rewrites its webhook configurations after it restarts, so the state
# immediately after the rollout is not yet the state that will be measured.
OBSERVED=""
CONVERGED=0
for _ in $(seq 1 60); do
  OBSERVED="$(pod_webhooks)"
  if [ -n "${OBSERVED}" ] \
     && ! printf '%s' "${OBSERVED}" | tr ' ' '\n' | grep -qv "=${WANT}\$"; then
    CONVERGED=1
    break
  fi
  sleep 3
done

echo "  after : ${OBSERVED:-<none>}"

jq -n \
  --arg mode "${MODE}" \
  --arg requested "${WANT}" \
  --arg force_ignore "${FORCE_IGNORE}" \
  --arg observed "${OBSERVED}" \
  --arg converged "${CONVERGED}" \
  --arg kyverno_image "$(kubectl get deployment kyverno-admission-controller \
      -n "${KYVERNO_NS}" -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || echo unknown)" \
  --arg replicas "$(kubectl get deployment kyverno-admission-controller \
      -n "${KYVERNO_NS}" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo unknown)" \
  --arg pdb "$(kubectl get poddisruptionbudget -n "${KYVERNO_NS}" \
      -o jsonpath='{range .items[*]}{.metadata.name}{"(minAvailable="}{.spec.minAvailable}{",allowed="}{.status.disruptionsAllowed}{") "}{end}' 2>/dev/null || echo none)" \
  --arg generated "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{configuration: $mode,
    requested_failure_policy: $requested,
    force_failure_policy_ignore: ($force_ignore == "true"),
    observed_pod_webhooks: $observed,
    converged: ($converged == "1"),
    kyverno_image: $kyverno_image,
    kyverno_ready_replicas: $replicas,
    pod_disruption_budgets: $pdb,
    generated: $generated}' \
  > "${RESULTS_DIR}/_failure_policy.json"

if [ "${CONVERGED}" != "1" ]; then
  echo ""
  echo "ERROR: the Pod-intercepting webhooks did not all reach failurePolicy=${WANT}."
  echo "Observed: ${OBSERVED:-<none>}"
  echo "Refusing to continue — an evidence run under an unknown admission"
  echo "configuration is worse than no evidence run."
  exit 1
fi

echo ""
echo "  PDB   : $(jq -r '.pod_disruption_budgets' "${RESULTS_DIR}/_failure_policy.json")"
echo "  ✅ every Pod-intercepting Kyverno webhook now reports ${WANT}"
echo "  settling ${SETTLE_SECONDS}s before any measurement"
sleep "${SETTLE_SECONDS}"
