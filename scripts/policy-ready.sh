#!/usr/bin/env bash
# policy-ready.sh — is a Kyverno ClusterPolicy ready to serve admission?
#
# Sourced, not executed:  source scripts/policy-ready.sh
#                         policy_ready verify-image-signature   # -> true|false|unknown
#
# ── Why this exists (defect D33) ─────────────────────────────────────────────
#
# Four places used to read `.status.ready` directly. That field is a plain bool
# in Kyverno v1.11.4 and is always serialised, so the check worked. In v1.18.2
# it is `*bool` with `omitempty`, and `PolicyStatus.SetReady()` explicitly does
#
#     status.Ready = nil
#
# after writing the condition — so the field is omitted from the object
# entirely, by design. Every one of those four readers therefore saw an empty
# string, reported `ready=unknown`, and the pipeline's preflight refused to run
# the admission tests against a cluster that was in fact perfectly healthy.
#
# The authority in both versions is the condition:
#
#     .status.conditions[?(@.type=="Ready")].status   # "True" / "False"
#
# v1.11.4 sets it too (PolicyConditionReady existed there), so the condition is
# checked first and the deprecated boolean is only a fallback for anything
# older. Reading both means this works across the upgrade rather than trading
# one version-specific bug for another.
#
# The three states are kept distinct on purpose. `unknown` means the policy
# could not be read at all — a missing policy, or no cluster access — and it
# must never be collapsed into `false`, because "not ready" and "not there" call
# for different action and this repository has already been bitten three times
# by a diagnostic that could not tell an absence from a refusal.

# policy_ready <clusterpolicy-name>  ->  echoes true | false | unknown
policy_ready() {
  local name="$1" cond legacy

  # The policy must exist at all; without this a missing policy and a
  # not-ready policy are indistinguishable.
  kubectl get clusterpolicy "${name}" >/dev/null 2>&1 || { echo unknown; return; }

  cond="$(kubectl get clusterpolicy "${name}" \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
  case "${cond}" in
    True)  echo true;  return ;;
    False) echo false; return ;;
  esac

  # Fallback: the deprecated boolean, for Kyverno older than the condition.
  legacy="$(kubectl get clusterpolicy "${name}" \
    -o jsonpath='{.status.ready}' 2>/dev/null || true)"
  case "${legacy}" in
    true)  echo true  ;;
    false) echo false ;;
    *)     echo unknown ;;
  esac
}

# policy_ready_reason <clusterpolicy-name> -> a human-readable message, for
# error paths. Empty when the policy is ready or unreadable.
policy_ready_reason() {
  kubectl get clusterpolicy "$1" \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].message}' 2>/dev/null || true
}
