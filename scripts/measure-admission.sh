#!/usr/bin/env bash
# scripts/measure-admission.sh
# Measure the admission cost of one condition, for .github/workflows/measure-admission-latency.yml.
#
# Two independent views of the same batch are recorded:
#
#   1. Kyverno's own histograms, as delta_sum/delta_count across every admission
#      replica. This is the authoritative mean per-admission time — it is the
#      webhook's own measurement of itself and contains no client or network cost.
#   2. Client-side wall clock around each create request, one row per request.
#      This is the only per-request sample available, so it is what percentile
#      and rank-based tests are computed from. It includes a constant kubectl
#      process startup and the runner-to-API-server round trip; those are equal
#      across conditions, so differences remain attributable, but absolute values
#      are inflated and must not be reported as admission latency.
#
# Probe pods are deliberately unschedulable (a nodeSelector no node satisfies).
# Admission runs in full — it happens at create time, before scheduling — while
# image pull, scheduling and container execution are excluded entirely. The
# previous version of this experiment timed pod completion, so the effect was
# buried under ~32 seconds of pull and schedule.
#
# Probes are created in the namespace the policies actually match. The previous
# version created them in `default`, which no policy matches, so no measurement
# ever exercised a policy.
#
# Usage: measure-admission.sh <condition> <image-ref> <iterations> [group]
set -euo pipefail

CONDITION="${1:?usage: measure-admission.sh <condition> <image-ref> <iterations> [group]}"
IMAGE="${2:?missing image reference}"
ITERATIONS="${3:?missing iteration count}"
GROUP="${4:-${CONDITION}}"

NAMESPACE="${NAMESPACE:-supply-chain-demo}"
RESULTS_DIR="${RESULTS_DIR:-/tmp/latency-results}"
WARMUP="${WARMUP:-3}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ "${ITERATIONS}" -lt 1 ] 2>/dev/null; then
  echo "Skipping ${CONDITION}: ${ITERATIONS} iterations requested."
  exit 0
fi

mkdir -p "${RESULTS_DIR}"
REQUESTS_CSV="${RESULTS_DIR}/requests.csv"
if [ ! -f "${REQUESTS_CSV}" ]; then
  echo "condition,group,iteration,client_ms,accepted" > "${REQUESTS_CSV}"
fi

# ── Probe manifest ────────────────────────────────────────────────────────────
# Defined in probe-lib.sh, shared with the concurrency sweep so that both
# experiments measure admission of the same kind of object. See that file for why
# the probe is unschedulable and why the namespace matters.
# shellcheck source=probe-lib.sh
source "${HERE}/probe-lib.sh"

echo "════════════════════════════════════════════════════════════"
echo "  Condition: ${CONDITION}   group: ${GROUP}"
echo "  Image    : ${IMAGE}"
echo "  Namespace: ${NAMESPACE}   iterations: ${ITERATIONS}"
echo "════════════════════════════════════════════════════════════"

# ── Warm-up ───────────────────────────────────────────────────────────────────
# Excluded from the measurement window. The first verification of an image pays
# one-off costs — registry client setup, TLS handshakes, and any first-use cache
# population — that are not representative of steady-state admission.
for i in $(seq 1 "${WARMUP}"); do
  create_probe "lat-${CONDITION}-warmup-${i}" "${CONDITION}" "${IMAGE}" >/dev/null
done
echo "Warm-up complete (${WARMUP} requests, not counted)"

# ── Measured window ───────────────────────────────────────────────────────────
python3 "${HERE}/kyverno_metrics.py" snapshot \
  --out "${RESULTS_DIR}/${CONDITION}-before.json" --apiserver

ADMITTED=0
DENIED=0
for i in $(seq 1 "${ITERATIONS}"); do
  POD="lat-${CONDITION}-${i}"
  START=$(date +%s%3N)
  ACCEPTED=$(create_probe "${POD}" "${CONDITION}" "${IMAGE}")
  END=$(date +%s%3N)

  echo "${CONDITION},${GROUP},${i},$((END - START)),${ACCEPTED}" >> "${REQUESTS_CSV}"
  if [ "${ACCEPTED}" = "true" ]; then
    ADMITTED=$((ADMITTED + 1))
  else
    DENIED=$((DENIED + 1))
  fi
done

python3 "${HERE}/kyverno_metrics.py" snapshot \
  --out "${RESULTS_DIR}/${CONDITION}-after.json" --apiserver

# ── Deltas ────────────────────────────────────────────────────────────────────
# Both a namespace-filtered and an unfiltered delta are kept. The filtered one is
# the measurement; the unfiltered one shows whether other admission traffic
# shared the window, and covers the case where this Kyverno version labels the
# series differently than expected — an empty filtered result then says so
# instead of silently reporting nothing.
python3 "${HERE}/kyverno_metrics.py" delta \
  --before "${RESULTS_DIR}/${CONDITION}-before.json" \
  --after  "${RESULTS_DIR}/${CONDITION}-after.json" \
  --condition "${CONDITION}" \
  --filter "resource_namespace=${NAMESPACE}" \
  --out "${RESULTS_DIR}/${CONDITION}-delta.json"

python3 "${HERE}/kyverno_metrics.py" delta \
  --before "${RESULTS_DIR}/${CONDITION}-before.json" \
  --after  "${RESULTS_DIR}/${CONDITION}-after.json" \
  --condition "${CONDITION}-all-namespaces" \
  --out "${RESULTS_DIR}/${CONDITION}-delta-unfiltered.json" >/dev/null

FILTERED_N=$(python3 -c "
import json
d = json.load(open('${RESULTS_DIR}/${CONDITION}-delta.json'))
print(int(d['histograms']['kyverno_admission_review_duration_seconds']['aggregate']['delta_count'] or 0))
")

if [ "${FILTERED_N}" = "0" ]; then
  echo ""
  echo "WARNING: no admission-review series matched resource_namespace=${NAMESPACE}."
  echo "  Either the webhook did not evaluate these pods, or this Kyverno version"
  echo "  labels the metric differently. The unfiltered delta is recorded next to"
  echo "  it — check which labels the series actually carry before using either."
fi

echo ""
echo "Requests: ${ADMITTED} admitted, ${DENIED} denied (of ${ITERATIONS})"
echo "Admissions seen by Kyverno in ${NAMESPACE}: ${FILTERED_N}"

# ── Cleanup ───────────────────────────────────────────────────────────────────
# After the closing snapshot, so deletions never land inside the measured window.
probe_cleanup "${NAMESPACE}"
echo "Probe pods deleted"
