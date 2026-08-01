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
#
# THE SHUFFLE USED TO BE `shuf --random-source=<(yes "${RANDOM_SEED}")`, AND IT
# DID NOT RANDOMISE ANYTHING.
#
# `yes N` is a stream of one repeated string, and shuf consumes only a few bytes
# of it to permute three items. GitHub run ids are 11 digits that share their
# leading digits for months at a time, so the bytes shuf actually reads were
# effectively constant and every run produced the same permutation. Measured:
# 200 consecutive run ids all yield `baseline enforce audit`, and all three real
# runs to date — 30692789440, 30704230504, 30706207673 — recorded exactly that.
# The size loop had the same defect: 100 consecutive ids all yield
# `xlarge medium large small`.
#
# The consequence is not cosmetic. Enforce was measured second and audit third in
# every run ever performed, so the audit-vs-enforce difference is confounded with
# position in all of them, and the write-up's claim that conditions ran "in a
# randomised order" was untrue. What the old code actually delivered was a single
# re-ordering, fixed forever.
#
# python3's Mersenne Twister is seeded from the whole integer and gives a
# different permutation for adjacent run ids, which is the property that was
# wanted. It is still fully reproducible from the recorded seed.
CONDITIONS=(baseline audit enforce)

if [ -n "${CONDITION_ORDER:-}" ]; then
  # Escape hatch for breaking the confound above: a run can be told to measure a
  # specific order, e.g. CONDITION_ORDER="baseline audit enforce" to put audit
  # before enforce for once. Recorded in the artefact as such, so an artefact
  # never claims to be randomised when it was chosen.
  read -r -a ORDER <<< "${CONDITION_ORDER}"
  ORDER_SOURCE="explicit"

  # Validate before anything is measured. An unknown or missing condition would
  # otherwise surface inside the loop, after the cluster has already been
  # reconfigured and part of the matrix measured — a wasted run for a typo.
  if [ "${#ORDER[@]}" -ne "${#CONDITIONS[@]}" ]; then
    echo "ERROR: CONDITION_ORDER lists ${#ORDER[@]} conditions, expected ${#CONDITIONS[@]}." >&2
    echo "       got: '${CONDITION_ORDER}'" >&2
    echo "       expected a permutation of: ${CONDITIONS[*]}" >&2
    exit 2
  fi
  for want in "${CONDITIONS[@]}"; do
    found=0
    for got in "${ORDER[@]}"; do [ "${got}" = "${want}" ] && found=1; done
    if [ "${found}" != "1" ]; then
      echo "ERROR: CONDITION_ORDER is missing '${want}'." >&2
      echo "       got: '${CONDITION_ORDER}'" >&2
      echo "       expected a permutation of: ${CONDITIONS[*]}" >&2
      exit 2
    fi
  done
else
  ORDER_STR=$(python3 -c "import random,sys; c=list(sys.argv[2:]); random.Random(int(sys.argv[1])).shuffle(c); print(' '.join(c))" \
    "${RANDOM_SEED}" "${CONDITIONS[@]}")
  read -r -a ORDER <<< "${ORDER_STR}"
  ORDER_SOURCE="seeded-shuffle"
fi

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
  --arg source "${ORDER_SOURCE}" \
  --argjson order "$(printf '%s\n' "${ORDER[@]}" | jq -R . | jq -s .)" \
  '{condition_order: $order, random_seed: $seed, order_source: $source,
    settle_seconds: ($settle | tonumber), warmup_discarded: ($warmup | tonumber),
    rationale: (if $source == "explicit"
                then "order chosen explicitly via CONDITION_ORDER, not randomised — used to break the position confound recorded as D24"
                else "conditions randomised so no single condition systematically absorbs webhook re-registration after a policy change"
                end)}' \
  > "${RESULTS_DIR}/_order.json"

for condition in "${ORDER[@]}"; do
  apply_condition "${condition}"
  bash "${HERE}/measure-admission.sh" "${condition}" "${PROBE_IMAGE}" "${ITERATIONS}"
done

echo ""
echo "Matrix complete in order: ${ORDER[*]}"
