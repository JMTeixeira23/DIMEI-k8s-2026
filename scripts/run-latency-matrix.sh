#!/usr/bin/env bash
# scripts/run-latency-matrix.sh
# Runs the baseline / audit / enforce matrix in a randomised order.
#
# WHY RANDOMISED
#
# Each condition is preceded by a policy change, and Kyverno re-registers its
# webhooks after one. Run in a fixed order, whichever condition follows the
# heaviest transition absorbs the settling cost, and that shows up as a fat tail
# in exactly one condition — which is what happened on 2026-08-01, where audit
# alone had a p95 of 2743 ms and an IQR of 97 ms against 30 ms elsewhere.
# Randomising the order means no condition is systematically the one that pays,
# so a tail that survives is a property of the condition rather than of its
# position in the sequence.
#
# Each transition is also waited out explicitly rather than slept through: the
# script blocks until the cluster reports the state it just asked for, then
# settles, then discards warm-up requests inside measure-admission.sh.
#
# The order actually executed is recorded, with its seed, so a run can be
# repeated exactly.
#
# Required env: PROBE_IMAGE, CLOUD, ITERATIONS
# Optional env: RESULTS_DIR, NAMESPACE, SETTLE_SECONDS, WARMUP, RANDOM_SEED
set -euo pipefail

: "${PROBE_IMAGE:?PROBE_IMAGE is required}"
: "${CLOUD:?CLOUD is required}"
: "${ITERATIONS:?ITERATIONS is required}"

RESULTS_DIR="${RESULTS_DIR:-/tmp/latency-results}"
NAMESPACE="${NAMESPACE:-supply-chain-demo}"
SETTLE_SECONDS="${SETTLE_SECONDS:-30}"
WARMUP="${WARMUP:-5}"
RANDOM_SEED="${RANDOM_SEED:-${GITHUB_RUN_ID:-1}}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POLICIES=(verify-image-signature verify-sbom-cyclonedx verify-slsa-provenance)

mkdir -p "${RESULTS_DIR}"
export RESULTS_DIR NAMESPACE WARMUP

render_policies() {  # <target-dir> <failure-action|keep>
  local dir="$1" action="$2" registry
  registry=$(grep '^REGISTRY=' "policies/values/${CLOUD}.env" | cut -d= -f2)
  mkdir -p "${dir}"
  for f in policies/verify-*.yaml; do
    if [ "${action}" = "keep" ]; then
      sed "s|REGISTRY_PLACEHOLDER|${registry}|g" "$f" > "${dir}/$(basename "$f")"
    else
      sed "s|REGISTRY_PLACEHOLDER|${registry}|g" "$f" \
        | sed "s/validationFailureAction: .*/validationFailureAction: ${action}/" \
        > "${dir}/$(basename "$f")"
    fi
  done
}

wait_until_absent() {
  for _ in $(seq 1 30); do
    if ! kubectl get clusterpolicy "${POLICIES[0]}" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  echo "WARNING: policies still present after waiting; continuing anyway" >&2
}

wait_until_ready() {  # <expected validationFailureAction>
  local want="$1" ok
  for _ in $(seq 1 45); do
    ok=1
    for p in "${POLICIES[@]}"; do
      local action ready
      action=$(kubectl get clusterpolicy "$p" \
        -o jsonpath='{.spec.validationFailureAction}' 2>/dev/null || true)
      ready=$(kubectl get clusterpolicy "$p" \
        -o jsonpath='{.status.ready}' 2>/dev/null || true)
      if [ "${action}" != "${want}" ] || [ "${ready}" != "true" ]; then
        ok=0
      fi
    done
    [ "${ok}" = "1" ] && return 0
    sleep 2
  done
  echo "WARNING: policies did not all reach ${want}/ready; continuing anyway" >&2
}

apply_condition() {  # <condition>
  case "$1" in
    baseline)
      echo "▶ baseline: removing the policies"
      kubectl delete clusterpolicy "${POLICIES[@]}" --ignore-not-found >/dev/null
      wait_until_absent
      ;;
    audit)
      echo "▶ audit: applying the policies in Audit mode"
      render_policies /tmp/kyverno-audit Audit
      kubectl apply --server-side --force-conflicts -f /tmp/kyverno-audit/ >/dev/null
      wait_until_ready Audit
      ;;
    enforce)
      echo "▶ enforce: applying the policies exactly as deployed"
      render_policies /tmp/kyverno-enforce keep
      kubectl apply --server-side --force-conflicts -f /tmp/kyverno-enforce/ >/dev/null
      wait_until_ready Enforce
      ;;
    *)
      echo "unknown condition: $1" >&2
      return 1
      ;;
  esac
  echo "  settling for ${SETTLE_SECONDS}s after the transition"
  sleep "${SETTLE_SECONDS}"
}

# ── Order ─────────────────────────────────────────────────────────────────────
CONDITIONS=(baseline audit enforce)
mapfile -t ORDER < <(printf '%s\n' "${CONDITIONS[@]}" \
  | shuf --random-source=<(yes "${RANDOM_SEED}"))

echo "════════════════════════════════════════════════════════════"
echo "  Latency matrix — ${CLOUD}"
echo "  Order : ${ORDER[*]}   (seed ${RANDOM_SEED})"
echo "  n     : ${ITERATIONS} per condition, ${WARMUP} warm-up discarded"
echo "  Settle: ${SETTLE_SECONDS}s after each policy transition"
echo "════════════════════════════════════════════════════════════"

jq -n \
  --arg seed "${RANDOM_SEED}" \
  --arg settle "${SETTLE_SECONDS}" \
  --arg warmup "${WARMUP}" \
  --argjson order "$(printf '%s\n' "${ORDER[@]}" | jq -R . | jq -s .)" \
  '{condition_order: $order, random_seed: $seed,
    settle_seconds: ($settle | tonumber), warmup_discarded: ($warmup | tonumber),
    rationale: "conditions randomised so no single condition systematically absorbs webhook re-registration after a policy change"}' \
  > "${RESULTS_DIR}/_order.json"

for condition in "${ORDER[@]}"; do
  apply_condition "${condition}"
  bash "${HERE}/measure-admission.sh" "${condition}" "${PROBE_IMAGE}" "${ITERATIONS}"
done

echo ""
echo "Matrix complete in order: ${ORDER[*]}"
