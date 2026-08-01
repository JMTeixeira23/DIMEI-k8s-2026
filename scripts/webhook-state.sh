#!/usr/bin/env bash
# scripts/webhook-state.sh
#
# Prints, as a JSON object on stdout, the admission configuration that any
# evidence run is executing under. Used by all three workflows' preflight steps
# so that every artefact — attack results, pipeline test cases, latency —
# carries the same self-description in the same shape.
#
# WHICH WEBHOOKS COUNT
#
# Only the ones that carry ClusterPolicy rules: Kyverno's *resource* webhooks,
# named `validate.kyverno.svc-<suffix>` and `mutate.kyverno.svc-<suffix>`. Those
# are the ones `forceFailurePolicyIgnore` moves between the `-ignore` and
# `-fail` pair, and the only ones whose failure policy decides what happens to a
# pod when Kyverno is unreachable.
#
# The first version of this script selected on the rules instead, matching any
# Kyverno webhook whose rules mention `pods` or `*`. That also caught
# `kyverno-cleanup-controller.kyverno.svc`, which belongs to the cleanup
# controller, is not affected by the feature flag, and stays `Ignore`. The
# effect was a permanent false negative: under fail-closed the set could never be
# unanimous, so the configuration was reported as `mixed` and
# set-failure-policy.sh aborted a run that had in fact succeeded — observed on
# run 30703345799, where the switch demonstrably worked
# (`mutate.kyverno.svc-fail=Fail validate.kyverno.svc-fail=Fail`) and was
# rejected anyway.
#
# Everything else Kyverno registers is still reported, under
# `other_kyverno_webhooks`, so nothing is hidden — it is context, not a verdict.
#
#   configuration            "fail-open" | "fail-closed" | "mixed" | "unknown"
#   policy_webhooks          the resource webhooks, as "name=failurePolicy"
#   other_kyverno_webhooks   everything else Kyverno owns, same format
#   webhook_timeout_seconds  the bound on how long admission stalls before the
#                            failure policy decides the outcome
#   pod_disruption_budgets   what protects the admission service during drains;
#                            "none" is a meaningful answer under fail-closed
#
# "mixed" is a real possible answer and is deliberately not collapsed into one
# of the other two: it means the policy webhooks disagree with each other, and
# any result gathered in that state is not attributable.
#
# Usage:  bash scripts/webhook-state.sh          # JSON to stdout
set -euo pipefail

KYVERNO_NS="${KYVERNO_NS:-kyverno}"

ALL=$(kubectl get validatingwebhookconfigurations,mutatingwebhookconfigurations \
  -o json 2>/dev/null || echo '{"items":[]}')

# The resource webhooks: the ones ClusterPolicy rules are registered into.
POLICY_WEBHOOKS=$(printf '%s' "${ALL}" | jq -r '
  [ .items[]? | .webhooks[]?
    | select(.name | test("^(validate|mutate)\\.kyverno\\.svc"))
    | "\(.name)=\(.failurePolicy)" ] | unique | join(" ")' 2>/dev/null || true)

OTHER_WEBHOOKS=$(printf '%s' "${ALL}" | jq -r '
  [ .items[]? | select(.metadata.name | test("kyverno")) | .webhooks[]?
    | select(.name | test("^(validate|mutate)\\.kyverno\\.svc") | not)
    | "\(.name)=\(.failurePolicy)" ] | unique | join(" ")' 2>/dev/null || true)

TIMEOUTS=$(printf '%s' "${ALL}" | jq -r '
  [ .items[]? | .webhooks[]?
    | select(.name | test("^(validate|mutate)\\.kyverno\\.svc"))
    | .timeoutSeconds ] | unique | join(",")' 2>/dev/null || true)

CONFIG="unknown"
if [ -n "${POLICY_WEBHOOKS}" ]; then
  HAS_IGNORE=0; HAS_FAIL=0
  printf '%s' "${POLICY_WEBHOOKS}" | tr ' ' '\n' | grep -q '=Ignore$' && HAS_IGNORE=1
  printf '%s' "${POLICY_WEBHOOKS}" | tr ' ' '\n' | grep -q '=Fail$'   && HAS_FAIL=1
  if   [ "${HAS_IGNORE}" = "1" ] && [ "${HAS_FAIL}" = "0" ]; then CONFIG="fail-open"
  elif [ "${HAS_FAIL}" = "1" ] && [ "${HAS_IGNORE}" = "0" ]; then CONFIG="fail-closed"
  elif [ "${HAS_FAIL}" = "1" ] && [ "${HAS_IGNORE}" = "1" ]; then CONFIG="mixed"
  fi
fi

jq -n \
  --arg configuration "${CONFIG}" \
  --arg policy_webhooks "${POLICY_WEBHOOKS:-none}" \
  --arg other_webhooks "${OTHER_WEBHOOKS:-none}" \
  --arg timeouts "${TIMEOUTS:-unknown}" \
  --arg replicas "$(kubectl get deployment kyverno-admission-controller \
      -n "${KYVERNO_NS}" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo unknown)" \
  --arg desired "$(kubectl get deployment kyverno-admission-controller \
      -n "${KYVERNO_NS}" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo unknown)" \
  --arg pdb "$(kubectl get poddisruptionbudget -n "${KYVERNO_NS}" \
      -o jsonpath='{range .items[*]}{.metadata.name}{"(minAvailable="}{.spec.minAvailable}{",allowed="}{.status.disruptionsAllowed}{") "}{end}' 2>/dev/null || true)" \
  '{configuration: $configuration,
    policy_webhooks: $policy_webhooks,
    other_kyverno_webhooks: $other_webhooks,
    webhook_timeout_seconds: $timeouts,
    kyverno_ready_replicas: $replicas,
    kyverno_desired_replicas: $desired,
    pod_disruption_budgets: (if ($pdb | length) == 0 then "none" else ($pdb | rtrimstr(" ")) end)}'
