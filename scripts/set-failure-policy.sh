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
# Kyverno generates its webhook configurations at runtime. It creates *paired*
# webhooks — `…svc-ignore` and `…svc-fail` — and routes each policy's rules to
# whichever matches that policy's effective failure policy. The controller
# feature flag `forceFailurePolicyIgnore` forces every rule onto the `-ignore`
# side; turning it off lets each ClusterPolicy's own `failurePolicy` apply,
# which defaults to `Fail`. So the flag is the entire control surface, and this
# script is a Helm upgrade plus a verification loop.
#
# The repository used to patch the live WebhookConfiguration objects instead, in
# five places. That was removed: it fought whatever Kyverno wrote next, it gave
# `kubectl-patch` ownership of a field Helm also manages, and the copy in the
# pipeline would have reverted this experiment to fail-open mid-run.
#
# VERIFICATION
#
# The script does not trust the upgrade. It reads back Kyverno's *resource*
# webhooks — `validate.kyverno.svc-*` and `mutate.kyverno.svc-*`, the ones
# ClusterPolicy rules are registered into — and requires them all to report the
# requested failure policy. Other Kyverno webhooks are deliberately not part of
# the verdict: `kyverno-cleanup-controller.kyverno.svc` belongs to the cleanup
# controller, is not affected by the flag, and stays `Ignore` forever. Including
# it made this check unsatisfiable under fail-closed and aborted run
# 30703345799 even though the switch had worked.
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
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

case "${MODE}" in
  ignore) FORCE_IGNORE=true  ; WANT=Ignore ;;
  fail)   FORCE_IGNORE=false ; WANT=Fail   ;;
  *)
    echo "usage: $0 <ignore|fail>" >&2
    exit 2
    ;;
esac

mkdir -p "${RESULTS_DIR}"

# Kyverno's resource webhooks, as "name=failurePolicy". Selected by webhook name
# rather than by their rules — see the comment above and in webhook-state.sh.
policy_webhooks() {
  kubectl get validatingwebhookconfigurations,mutatingwebhookconfigurations \
    -o json 2>/dev/null \
  | jq -r '[ .items[]? | .webhooks[]?
             | select(.name | test("^(validate|mutate)\\.kyverno\\.svc"))
             | "\(.name)=\(.failurePolicy)" ] | unique | join(" ")' 2>/dev/null || true
}

# True when every resource webhook already reports the requested policy.
converged() {
  local observed="$1"
  [ -n "${observed}" ] || return 1
  ! printf '%s' "${observed}" | tr ' ' '\n' | grep -qv "=${WANT}\$"
}

record() {  # <observed> <converged 0|1> <action>
  jq -n \
    --arg mode "${MODE}" \
    --arg requested "${WANT}" \
    --arg force_ignore "${FORCE_IGNORE}" \
    --arg observed "$1" \
    --arg converged "$2" \
    --arg action "$3" \
    --argjson state "$(bash "${HERE}/webhook-state.sh" 2>/dev/null || echo '{}')" \
    --arg generated "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{configuration: $mode,
      requested_failure_policy: $requested,
      force_failure_policy_ignore: ($force_ignore == "true"),
      observed_policy_webhooks: $observed,
      converged: ($converged == "1"),
      action: $action,
      state: $state,
      generated: $generated}' \
    > "${RESULTS_DIR}/_failure_policy.json"
}

echo "════════════════════════════════════════════════════════════"
echo "  Admission failure policy → ${WANT}  (${MODE})"
echo "  forceFailurePolicyIgnore.enabled = ${FORCE_IGNORE}"
echo "════════════════════════════════════════════════════════════"

BEFORE="$(policy_webhooks)"
echo "  before: ${BEFORE:-<none>}"

# ── Are there any resource webhooks to verify at all? ────────────────────────
# Kyverno registers a resource webhook only when a policy rule needs one, and it
# omits the side of the `-ignore`/`-fail` pair that carries no rules. With no
# ClusterPolicies registered there is therefore nothing named
# `validate|mutate.kyverno.svc-*` in the cluster, and no amount of waiting will
# produce one: the flag would flip, Kyverno would restart, and the verification
# loop below would spend three minutes discovering that an empty set cannot
# unanimously report ${WANT}.
#
# That is a different failure from "the webhooks disagree with what was asked",
# and it is worth saying which one happened. Both bootstrap scripts and the
# latency workflow's restore step leave the policies applied, so this should not
# arise in an evidence sequence — but when it does, the run is unattributable for
# a reason the operator can act on, and it should fail here rather than after the
# upgrade.
if [ -z "${BEFORE}" ]; then
  POLICY_COUNT=$(kubectl get clusterpolicies -o name 2>/dev/null | wc -l | tr -d ' ')
  if [ "${POLICY_COUNT}" = "0" ]; then
    echo ""
    echo "ERROR: no ClusterPolicies are registered, so Kyverno has published no"
    echo "resource webhooks and the admission failure policy cannot be verified."
    echo "Apply the policies first (bootstrap-<cloud>.sh step 6, or the pipeline),"
    echo "then re-run this script. Refusing to switch a configuration that cannot"
    echo "be read back — an evidence run under an unknown admission configuration"
    echo "is worse than no evidence run."
    exit 3
  fi
  echo "  note  : ${POLICY_COUNT} ClusterPolicies exist but no resource webhooks are"
  echo "          published yet; Kyverno may still be registering them."
fi

# ── Already there? ───────────────────────────────────────────────────────────
# A Helm upgrade that changes nothing is not free: it restarts the admission
# controller, it takes a release lock, and on run 30703179531 it failed outright
# with "another operation (install/upgrade/rollback) is in progress" because a
# concurrent workflow held that lock. The cluster was already fail-open at the
# time, so the entire upgrade was unnecessary. Skipping when the requested state
# already holds makes this script idempotent and removes the most common way for
# it to fail.
if converged "${BEFORE}"; then
  echo "  ✅ already ${WANT} — no Helm upgrade needed"
  record "${BEFORE}" 1 "no-op"
  echo "  settling ${SETTLE_SECONDS}s before any measurement"
  sleep "${SETTLE_SECONDS}"
  exit 0
fi

# ── Wait out any Helm operation already in flight ────────────────────────────
# Two workflows pointed at one cluster will collide here. The concurrency groups
# on the workflows are the real fix; this is the backstop for a release left in
# a pending state by an interrupted run.
for attempt in $(seq 1 20); do
  STATUS=$(helm status "${KYVERNO_RELEASE}" -n "${KYVERNO_NS}" \
            -o json 2>/dev/null | jq -r '.info.status' 2>/dev/null || echo unknown)
  case "${STATUS}" in
    pending-install|pending-upgrade|pending-rollback|uninstalling)
      echo "  Helm release is ${STATUS}; waiting (${attempt}/20)"
      sleep 15
      ;;
    *)
      break
      ;;
  esac
done
if [ "${STATUS:-}" = "pending-upgrade" ] || [ "${STATUS:-}" = "pending-rollback" ]; then
  echo "  release still ${STATUS} after waiting — rolling back to the last good revision"
  helm rollback "${KYVERNO_RELEASE}" -n "${KYVERNO_NS}" --wait --timeout 5m || true
fi

helm repo add kyverno https://kyverno.github.io/kyverno/ >/dev/null 2>&1 || true
helm repo update kyverno >/dev/null 2>&1 || true

# --reuse-values keeps everything the bootstrap set, including the cloud-specific
# IRSA / workload-identity wiring that is passed as --set at install time and is
# not in the values file. Only the one flag changes.
#
# It also means changes to helm/kyverno-values.yaml do NOT arrive through this
# script — the PodDisruptionBudget in particular needs a bootstrap run.
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
OK=0
for _ in $(seq 1 60); do
  OBSERVED="$(policy_webhooks)"
  if converged "${OBSERVED}"; then OK=1; break; fi
  sleep 3
done

echo "  after : ${OBSERVED:-<none>}"
record "${OBSERVED}" "${OK}" "helm-upgrade"

if [ "${OK}" != "1" ]; then
  echo ""
  if [ -z "${OBSERVED}" ]; then
    echo "ERROR: Kyverno published no resource webhooks after the upgrade."
    echo "ClusterPolicies present: $(kubectl get clusterpolicies -o name 2>/dev/null | wc -l | tr -d ' ')"
    echo "This is not a disagreement about the failure policy — there is nothing"
    echo "to disagree. Check that the policies are applied and that the admission"
    echo "controller is running."
  else
    echo "ERROR: Kyverno's resource webhooks did not all reach failurePolicy=${WANT}."
    echo "Observed: ${OBSERVED}"
  fi
  echo "Refusing to continue — an evidence run under an unknown admission"
  echo "configuration is worse than no evidence run."
  exit 1
fi

echo ""
echo "  other : $(jq -r '.state.other_kyverno_webhooks // "unknown"' "${RESULTS_DIR}/_failure_policy.json")"
echo "  PDB   : $(jq -r '.state.pod_disruption_budgets // "unknown"' "${RESULTS_DIR}/_failure_policy.json")"
echo "  ✅ every Kyverno resource webhook now reports ${WANT}"
echo "  settling ${SETTLE_SECONDS}s before any measurement"
sleep "${SETTLE_SECONDS}"
