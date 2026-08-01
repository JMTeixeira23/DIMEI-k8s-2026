#!/usr/bin/env bash
# scripts/measure-concurrency.sh
# Revision item 1.4 — admission cost under concurrent pod creation.
#
# WHAT THIS ASKS
#
# Every other experiment in this project creates one pod at a time. Real clusters
# do not: a Deployment scaling up, a rollout, or a node rejoining creates many
# pods at once and they arrive at the webhook together. This sweep delivers the
# same number of requests at increasing concurrency and asks whether admission
# degrades, and whether three Kyverno replicas saturate.
#
# It matters most under fail-closed. There, a saturated webhook does not merely
# get slow — requests that exceed the 10 s timeout are *rejected*, so pod
# creation fails. The recommendation in changes.md 0.0.3 to run fail-closed in
# the enforcing namespace is only safe if there is headroom, and this is the
# measurement that establishes whether there is.
#
# DESIGN: EQUAL REQUESTS PER LEVEL, DELIVERED AT DIFFERENT CONCURRENCY
#
# Each level sends REQUESTS_PER_LEVEL requests in batches of N. Level 1 sends 50
# batches of 1; level 50 sends 1 batch of 50. Holding the request count constant
# is what makes the per-level distributions comparable — percentiles computed
# from 50 samples at one level and 5 at another are not.
#
# THE MEASUREMENT THAT CAN LIE, AND THE ONE THAT CANNOT
#
# At high concurrency the *client* becomes a suspect. Fifty simultaneous kubectl
# processes on a two-core runner queue against each other, and that queuing lands
# in the client-side wall clock exactly where webhook saturation would. Client
# timings at level 50 are therefore an upper bound on admission cost and must not
# be reported as if they were admission cost.
#
# Kyverno's own histogram is immune to it: delta_sum/delta_count measures time
# spent inside the webhook and knows nothing about how long a request waited in
# the runner. **If the in-webhook mean stays flat while the client-side p95
# climbs, the bottleneck is the client, not the webhook.** That comparison is the
# actual result of this experiment, and it is only available because the two
# channels were built to be independent.
#
# Usage: measure-concurrency.sh <image-ref> "<levels>" [requests-per-level]
#   measure-concurrency.sh "$IMG" "1 5 10 25 50" 50
set -euo pipefail

IMAGE="${1:?usage: measure-concurrency.sh <image-ref> \"<levels>\" [requests]}"
LEVELS_RAW="${2:?missing concurrency levels, e.g. \"1 5 10 25 50\"}"
REQUESTS_PER_LEVEL="${3:-50}"

NAMESPACE="${NAMESPACE:-supply-chain-demo}"
RESULTS_DIR="${RESULTS_DIR:-/tmp/latency-results}"
WARMUP="${WARMUP:-5}"
SETTLE_SECONDS="${SETTLE_SECONDS:-10}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=probe-lib.sh
source "${HERE}/probe-lib.sh"

read -r -a LEVELS <<< "${LEVELS_RAW}"
if [ "${#LEVELS[@]}" -eq 0 ]; then
  echo "No concurrency levels requested; skipping." >&2
  exit 0
fi
for lvl in "${LEVELS[@]}"; do
  if ! [ "${lvl}" -ge 1 ] 2>/dev/null; then
    echo "ERROR: '${lvl}' is not a positive integer concurrency level." >&2
    exit 2
  fi
done

mkdir -p "${RESULTS_DIR}"
REQUESTS_CSV="${RESULTS_DIR}/requests.csv"
if [ ! -f "${REQUESTS_CSV}" ]; then
  echo "condition,group,iteration,client_ms,accepted" > "${REQUESTS_CSV}"
fi

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

THROUGHPUT_JSON="${RESULTS_DIR}/_concurrency.json"
echo '[]' > "${THROUGHPUT_JSON}"

echo "════════════════════════════════════════════════════════════"
echo "  Concurrency sweep"
echo "  Levels   : ${LEVELS[*]}"
echo "  Requests : ${REQUESTS_PER_LEVEL} per level"
echo "  Image    : ${IMAGE}"
echo "  Namespace: ${NAMESPACE}"
echo "════════════════════════════════════════════════════════════"

for LEVEL in "${LEVELS[@]}"; do
  CONDITION=$(printf 'conc-%03d' "${LEVEL}")
  BATCHES=$(( (REQUESTS_PER_LEVEL + LEVEL - 1) / LEVEL ))
  PLANNED=$(( BATCHES * LEVEL ))

  echo ""
  echo "── ${CONDITION}: ${LEVEL} concurrent × ${BATCHES} batches = ${PLANNED} requests ──"

  # Warm-up, sequential and unrecorded: the first verification of an image pays
  # one-off registry and TLS costs that are not steady-state admission.
  for i in $(seq 1 "${WARMUP}"); do
    create_probe "cw-${CONDITION}-${i}" "${CONDITION}" "${IMAGE}" >/dev/null
  done

  python3 "${HERE}/kyverno_metrics.py" snapshot \
    --out "${RESULTS_DIR}/${CONDITION}-before.json" --apiserver

  BATCH_WALL_TOTAL=0
  IDX=0
  for b in $(seq 1 "${BATCHES}"); do
    BATCH_START=$(date +%s%3N)

    for j in $(seq 1 "${LEVEL}"); do
      IDX=$((IDX + 1))
      (
        POD="c-${CONDITION}-${b}-${j}"
        S=$(date +%s%3N)
        A=$(create_probe "${POD}" "${CONDITION}" "${IMAGE}")
        E=$(date +%s%3N)
        # One file per worker: concurrent appends to a shared file interleave and
        # corrupt rows. Collected in order after the batch drains.
        printf '%s,%s,%s,%s,%s\n' \
          "${CONDITION}" "concurrency" "${IDX}" "$((E - S))" "${A}" \
          > "${WORK}/row-${b}-${j}"
      ) &
    done
    wait

    BATCH_END=$(date +%s%3N)
    BATCH_WALL_TOTAL=$(( BATCH_WALL_TOTAL + (BATCH_END - BATCH_START) ))
  done

  python3 "${HERE}/kyverno_metrics.py" snapshot \
    --out "${RESULTS_DIR}/${CONDITION}-after.json" --apiserver

  # Rows are appended only after the closing snapshot, in deterministic order.
  cat "${WORK}"/row-* >> "${REQUESTS_CSV}"
  rm -f "${WORK}"/row-*

  python3 "${HERE}/kyverno_metrics.py" delta \
    --before "${RESULTS_DIR}/${CONDITION}-before.json" \
    --after  "${RESULTS_DIR}/${CONDITION}-after.json" \
    --condition "${CONDITION}" \
    --filter "resource_namespace=${NAMESPACE}" \
    --out "${RESULTS_DIR}/${CONDITION}-delta.json" >/dev/null

  ACCEPTED=$(awk -F, -v c="${CONDITION}" '$1==c && $5=="true"' "${REQUESTS_CSV}" | wc -l)
  REJECTED=$(awk -F, -v c="${CONDITION}" '$1==c && $5!="true"' "${REQUESTS_CSV}" | wc -l)

  # Throughput is requests divided by the wall time actually spent issuing them,
  # summed over batches. Inter-batch bookkeeping is excluded, so this is the rate
  # the cluster sustained rather than the rate this script achieved.
  THROUGHPUT=$(python3 -c "
w = ${BATCH_WALL_TOTAL} / 1000.0
print(round(${PLANNED} / w, 2) if w > 0 else 0)")

  python3 - "${THROUGHPUT_JSON}" <<PY
import json, sys
path = sys.argv[1]
rows = json.load(open(path))
rows.append({
    "condition": "${CONDITION}",
    "concurrency": ${LEVEL},
    "batches": ${BATCHES},
    "requests": ${PLANNED},
    "accepted": ${ACCEPTED},
    "rejected": ${REJECTED},
    "wall_ms_total": ${BATCH_WALL_TOTAL},
    "throughput_admissions_per_s": ${THROUGHPUT},
})
json.dump(rows, open(path, "w"), indent=2)
PY

  echo "  ${ACCEPTED} accepted, ${REJECTED} rejected, ${BATCH_WALL_TOTAL} ms wall, ${THROUGHPUT} admissions/s"
  if [ "${REJECTED}" -gt 0 ]; then
    echo "  ⚠ rejections at concurrency ${LEVEL} — under fail-closed this is what"
    echo "    saturation looks like. Check the messages before interpreting."
  fi

  probe_cleanup "${NAMESPACE}"
  sleep "${SETTLE_SECONDS}"
done

echo ""
echo "Sweep complete. Per-level throughput in ${THROUGHPUT_JSON}"
