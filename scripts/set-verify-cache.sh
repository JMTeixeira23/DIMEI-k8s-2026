#!/usr/bin/env bash
# scripts/set-verify-cache.sh <on|off>
#
# Switches Kyverno's image verification cache, and records which state the
# cluster is actually in so a latency artefact can name it.
#
# WHY THIS EXISTS (defect D13, reopened 2026-08-15)
#
# Kyverno v1.11.4 had no image verification cache — the flag did not exist, and
# D13 was closed on that basis, which is why revision.md §1.1 dropped its
# warm/cold split and §2.1 dropped "how long does the cache mask a Rekor
# outage". Kyverno v1.18.2 ships one and enables it by default:
#
#   imageVerifyCacheEnabled=true  imageVerifyCacheMaxSize=1000  TTL=1h
#
# That changes what the latency experiment measures. `run-latency-matrix.sh`
# reuses one probe digest, so with the cache on, the first admission pays the
# Rekor round trip and every later one does not. Conditions measured second and
# third would be systematically cheaper — the same positional confound D15 and
# D24 were fixed to eliminate, but now with a known mechanism rather than
# session drift.
#
# So cache state becomes an explicit condition, measured both ways, exactly as
# condition order became explicit after D24.
#
#   on   the shipped default. What a production cluster runs, and the
#        configuration RQ2's "acceptable performance" should be judged against.
#   off  every admission pays full verification. The worst case, and the only
#        state comparable to the v1.11.4 results, which had no cache at all.
#
# ⚠️ THE FLAG VALUE MUST BE A QUOTED STRING
#
# The chart renders extraArgs as
#     {{- range $key, $value := .Values.admissionController.container.extraArgs }}
#     {{- if $value }}
#     - --{{ $key }}={{ $value }}
# and a YAML boolean `false` is falsy in Go templates, so
# `imageVerifyCacheEnabled: false` renders nothing at all and the flag keeps its
# default of true. Measured: `false` -> 0 occurrences, `"false"` -> 1, `0` -> 0.
# This script therefore passes --set-string. Getting it wrong does not error —
# it silently measures the cache-on condition twice.
#
# VERIFICATION
#
# The script does not trust the upgrade. It reads the flag back off the running
# containers' argument list and requires every replica to agree, because a
# rolling upgrade can leave old and new pods side by side and a matrix that
# starts in that window measures a mixture of both conditions.
#
# Usage:
#   bash scripts/set-verify-cache.sh off
#   RESULTS_DIR=/tmp/x bash scripts/set-verify-cache.sh on
set -euo pipefail

MODE="${1:-}"
KYVERNO_NS="${KYVERNO_NS:-kyverno}"
KYVERNO_RELEASE="${KYVERNO_RELEASE:-kyverno}"
RESULTS_DIR="${RESULTS_DIR:-/tmp/verify-cache}"
SETTLE_SECONDS="${SETTLE_SECONDS:-20}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The chart version must be the one the cluster was built on — a helm upgrade
# with a different --version moves the cluster to another Kyverno mid-experiment.
# shellcheck source=../versions.env
source "$(cd "${HERE}/.." && pwd)/versions.env"
KYVERNO_VERSION="${KYVERNO_VERSION:-${KYVERNO_CHART_VERSION}}"

case "${MODE}" in
  on)  WANT="true"  ;;
  off) WANT="false" ;;
  *)   echo "usage: $0 <on|off>" >&2; exit 2 ;;
esac

# ── Refuse to roll the deployment under a running measurement (defect D40) ───
#
# Changing this flag is a helm upgrade, which rolls kyverno-admission-controller.
# If a measurement workflow is mid-run when that happens the run is silently
# ruined in three ways at once: the metrics baseline it snapshotted is gone, the
# verification cache it was characterising is emptied, and a scrape can address a
# pod that no longer exists. Observed on 2026-08-15 — six Azure performance runs
# dispatched back to back with cache flips between them; one failed with
# `pods "kyverno-admission-controller-…" not found`, one "succeeded" having
# measured across a restart, and the rest were cancelled by the concurrency group.
#
# The dangerous outcome is the middle one. A run that completes across a restart
# produces a plausible artefact recording a single cache state that was not the
# state in force for the whole run, and nothing downstream can detect it.
#
# Skipped when gh is unavailable or unauthenticated — this is a guard against an
# ordering mistake, not an authorisation check. SKIP_RUN_CHECK=1 overrides it.
#
# Filtered with jq rather than `gh run list --status`: that flag is absent in
# some gh versions, and when it is the command errors, `|| true` swallows it, the
# result is empty and the guard reads as "nothing running" — it never fires and
# still looks like it passed. The first version of this check had exactly that
# bug, and testing it while nothing was running could not tell the two apart.
if [ "${SKIP_RUN_CHECK:-0}" != "1" ] && command -v gh >/dev/null 2>&1; then
  BUSY=$(gh run list --workflow=measure-admission-latency.yml --limit 20 \
           --json databaseId,status \
           -q '[.[] | select(.status == "in_progress" or .status == "queued"
                             or .status == "pending" or .status == "requested"
                             or .status == "waiting")]
               | map(.databaseId | tostring) | join(" ")' 2>/dev/null || true)
  if [ -n "${BUSY// /}" ]; then
    echo "❌ A measurement workflow is in progress or queued:${BUSY}" >&2
    echo "" >&2
    echo "   Changing the cache flag rolls the admission controller and would" >&2
    echo "   ruin that run without failing it — see defect D40. Wait for it to" >&2
    echo "   finish, then re-run this script." >&2
    echo "" >&2
    echo "     gh run watch ${BUSY%% *}" >&2
    echo "" >&2
    echo "   Override only if you know the run is already being discarded:" >&2
    echo "     SKIP_RUN_CHECK=1 $0 ${MODE}" >&2
    exit 7
  fi
fi

mkdir -p "${RESULTS_DIR}"

# The flag as every running admission-controller container reports it, one line
# per pod. Empty when no pod carries the flag at all.
observed_flags() {
  kubectl get pods -n "${KYVERNO_NS}" \
    -l app.kubernetes.io/component=admission-controller \
    -o json 2>/dev/null \
  | jq -r '[ .items[]?
             | select(.status.phase == "Running")
             | .spec.containers[]? | select(.name == "kyverno")
             | ( [ .args[]? | select(startswith("--imageVerifyCacheEnabled")) ][0]
                 // "--imageVerifyCacheEnabled=true(default)" ) ] | join(" ")' \
    2>/dev/null || true
}

# Every replica must report the requested value; a mixed fleet is not converged.
converged() {
  local observed="$1"
  [ -n "${observed}" ] || return 1
  ! printf '%s' "${observed}" | tr ' ' '\n' \
    | grep -qv "^--imageVerifyCacheEnabled=${WANT}"
}

record() {  # <observed> <converged 0|1> <action>
  jq -n \
    --arg mode "${MODE}" \
    --arg requested "${WANT}" \
    --arg observed "$1" \
    --arg converged "$2" \
    --arg action "$3" \
    --arg replicas "$(kubectl get deployment kyverno-admission-controller \
        -n "${KYVERNO_NS}" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo unknown)" \
    --arg generated "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{image_verify_cache: $mode,
      requested: ($requested == "true"),
      observed_container_flags: $observed,
      converged: ($converged == "1"),
      action: $action,
      ready_replicas: $replicas,
      note: "Kyverno v1.18.2 enables this cache by default (maxSize 1000, TTL 1h). Kyverno v1.11.4, which the superseded results were collected on, had no cache at all — every admission there paid the Rekor round trip, so only the off state is comparable to them.",
      generated: $generated}' \
    > "${RESULTS_DIR}/verify-cache-state.json"
  cat "${RESULTS_DIR}/verify-cache-state.json"
}

echo "▶ Image verification cache -> ${MODE} (--imageVerifyCacheEnabled=${WANT})"

BEFORE="$(observed_flags)"
echo "  before: ${BEFORE:-<no running admission controller>}"

if converged "${BEFORE}"; then
  echo "  ✅ already ${MODE}; no upgrade performed"
  record "${BEFORE}" 1 "none — already in the requested state"
  exit 0
fi

helm upgrade --install "${KYVERNO_RELEASE}" kyverno/kyverno \
  --values "$(cd "${HERE}/.." && pwd)/helm/kyverno-values.yaml" \
  --namespace "${KYVERNO_NS}" \
  --version "${KYVERNO_VERSION}" \
  --reuse-values \
  --set-string "admissionController.container.extraArgs.imageVerifyCacheEnabled=${WANT}" \
  --timeout 5m \
  --no-hooks \
  --wait

kubectl rollout status deployment/kyverno-admission-controller \
  -n "${KYVERNO_NS}" --timeout=5m

# Let the webhooks settle before anything measures through them, for the same
# reason run-latency-matrix.sh settles: a request served during registration is
# not measuring steady state.
sleep "${SETTLE_SECONDS}"

AFTER="$(observed_flags)"
echo "  after:  ${AFTER:-<none>}"

if ! converged "${AFTER}"; then
  echo ""
  echo "❌ the cache flag did not converge to ${WANT} on every replica."
  echo "   Observed: ${AFTER:-<none>}"
  echo "   A latency run started now would measure a mixture of both conditions."
  echo "   The most likely cause is the Go-template falsiness trap described at"
  echo "   the top of this script: an unquoted false renders no flag at all."
  record "${AFTER}" 0 "helm upgrade, did not converge"
  exit 3
fi

echo "  ✅ every replica reports --imageVerifyCacheEnabled=${WANT}"
record "${AFTER}" 1 "helm upgrade to ${WANT}"
