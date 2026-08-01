#!/usr/bin/env bash
# scripts/webhook-state.sh
#
# Prints, as a JSON object on stdout, the admission configuration that any
# evidence run is executing under. Used by all three workflows' preflight steps
# so that every artefact — attack results, pipeline test cases, latency —
# carries the same self-description in the same shape.
#
# Revision item 1.3 asks for the fail-open and fail-closed configurations to be
# reported side by side. That is only possible if each artefact says which one
# produced it, and says it from what the cluster reported rather than from what
# the workflow input requested.
#
#   configuration            "fail-open" | "fail-closed" | "mixed" | "unknown"
#   pod_webhooks             every Kyverno webhook that intercepts a Pod create,
#                            as "name=failurePolicy", so the claim is checkable
#   webhook_timeout_seconds  the bound on how long admission stalls before the
#                            failure policy decides the outcome
#   pod_disruption_budgets   what protects the admission service during drains;
#                            "none" is a meaningful answer under fail-closed
#
# "mixed" is a real possible answer and is deliberately not collapsed into one
# of the other two: it means some Pod-intercepting webhook disagrees with the
# others, and any result gathered in that state is not attributable.
#
# Usage:  bash scripts/webhook-state.sh          # JSON to stdout
set -euo pipefail

KYVERNO_NS="${KYVERNO_NS:-kyverno}"

WEBHOOKS=$(kubectl get validatingwebhookconfigurations,mutatingwebhookconfigurations \
  -o json 2>/dev/null \
  | jq -r '
      [ .items[]
        | select(.metadata.name | test("kyverno"))
        | .webhooks[]?
        | select(any(.rules[]?;
            (.resources[]? == "pods") or (.resources[]? == "*")))
        | "\(.name)=\(.failurePolicy)" ]
      | unique | join(" ")' 2>/dev/null || true)

TIMEOUTS=$(kubectl get validatingwebhookconfigurations,mutatingwebhookconfigurations \
  -o json 2>/dev/null \
  | jq -r '[ .items[]
             | select(.metadata.name | test("kyverno"))
             | .webhooks[]? | .timeoutSeconds ] | unique | join(",")' \
  2>/dev/null || true)

CONFIG="unknown"
if [ -n "${WEBHOOKS}" ]; then
  HAS_IGNORE=0; HAS_FAIL=0
  printf '%s' "${WEBHOOKS}" | tr ' ' '\n' | grep -q '=Ignore$' && HAS_IGNORE=1
  printf '%s' "${WEBHOOKS}" | tr ' ' '\n' | grep -q '=Fail$'   && HAS_FAIL=1
  if   [ "${HAS_IGNORE}" = "1" ] && [ "${HAS_FAIL}" = "0" ]; then CONFIG="fail-open"
  elif [ "${HAS_FAIL}" = "1" ] && [ "${HAS_IGNORE}" = "0" ]; then CONFIG="fail-closed"
  elif [ "${HAS_FAIL}" = "1" ] && [ "${HAS_IGNORE}" = "1" ]; then CONFIG="mixed"
  fi
fi

jq -n \
  --arg configuration "${CONFIG}" \
  --arg pod_webhooks "${WEBHOOKS:-none}" \
  --arg timeouts "${TIMEOUTS:-unknown}" \
  --arg replicas "$(kubectl get deployment kyverno-admission-controller \
      -n "${KYVERNO_NS}" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo unknown)" \
  --arg desired "$(kubectl get deployment kyverno-admission-controller \
      -n "${KYVERNO_NS}" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo unknown)" \
  --arg pdb "$(kubectl get poddisruptionbudget -n "${KYVERNO_NS}" \
      -o jsonpath='{range .items[*]}{.metadata.name}{"(minAvailable="}{.spec.minAvailable}{",allowed="}{.status.disruptionsAllowed}{") "}{end}' 2>/dev/null || true)" \
  '{configuration: $configuration,
    pod_webhooks: $pod_webhooks,
    webhook_timeout_seconds: $timeouts,
    kyverno_ready_replicas: $replicas,
    kyverno_desired_replicas: $desired,
    pod_disruption_budgets: (if ($pdb | length) == 0 then "none" else ($pdb | rtrimstr(" ")) end)}'
