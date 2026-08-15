#!/usr/bin/env bash
# scripts/run-perf-suite.sh <aws|azure>
#
# Runs the six performance arms end to end, one at a time, and verifies each
# artefact recorded the cache state it was supposed to be measuring.
#
# WHY THIS EXISTS (defect D40)
#
# The six arms were previously dispatched by hand as six commands with
# `set-verify-cache.sh` calls between them. Pasted as a block on 2026-08-15 they
# destroyed each other: each cache flip is a helm upgrade that rolls
# kyverno-admission-controller, and a roll under a running measurement empties
# the cache being characterised, resets the metrics baseline the run snapshotted,
# and can leave a scrape addressing a pod that no longer exists. One run failed
# outright, one completed having measured across a restart — the dangerous one,
# because its artefact looks entirely normal — and the concurrency group
# cancelled the rest.
#
# The fix is sequencing, so the sequencing is code rather than instructions.
#
# ARM ORDER
#
# Grouped by cache state, not by experiment, so the flag is flipped twice rather
# than five times. Fewer rolls is fewer opportunities for the failure above, and
# the arms within a group are independent of each other.
#
#   cache off : latency matrix, size matrix, concurrency sweep
#   cache on  : latency matrix, size matrix, concurrency sweep
#
# Each arm: set the state, wait for convergence, dispatch, watch to completion,
# then read the artefact back and require it to name the state we asked for. A
# run whose artefact disagrees stops the suite — that is D34's trap, and it is
# cheaper to stop than to discover it after all six have run.
#
# Usage:
#   bash scripts/run-perf-suite.sh azure
#   ARMS="lat-off cc-on" bash scripts/run-perf-suite.sh azure   # subset, to resume
set -uo pipefail

CLOUD="${1:-}"
case "${CLOUD}" in
  aws|azure) ;;
  *) echo "usage: $0 <aws|azure>" >&2; exit 2 ;;
esac

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${HERE}"

WF=measure-admission-latency.yml
ITER="${ITER:-30}"
SIZE_ITER="${SIZE_ITER:-20}"
CC_LEVELS="${CC_LEVELS:-1 5 10 25 50}"
CC_REQS="${CC_REQS:-50}"
ARMS="${ARMS:-lat-off sz-off cc-off lat-on sz-on cc-on}"

log() { printf '\n\033[1m%s\033[0m\n' "$*"; }

# Dispatch and return the id of the run that dispatch created. `gh run list`
# right after a dispatch can still return the previous run, so we wait for an id
# we have not seen before rather than trusting --limit 1.
dispatch() {  # dispatch <field=value>...
  local before after id
  before=$(gh run list --workflow="${WF}" --limit 1 --json databaseId -q '.[0].databaseId' 2>/dev/null || echo none)
  gh workflow run "${WF}" "$@" >/dev/null || return 1
  for _ in $(seq 1 30); do
    sleep 3
    after=$(gh run list --workflow="${WF}" --limit 1 --json databaseId -q '.[0].databaseId' 2>/dev/null || echo none)
    if [ "${after}" != "${before}" ] && [ "${after}" != none ]; then
      printf '%s' "${after}"; return 0
    fi
  done
  return 1
}

# Wait for a run to leave queued/in_progress. Deliberately not `gh run watch`:
# this must work unattended and must not exit non-zero merely because the run
# failed — we want to report which arm failed, not abort in the middle.
await() {  # await <run-id> ; echoes the conclusion
  local id="$1" st
  while :; do
    st=$(gh run view "${id}" --json status,conclusion -q '"\(.status)|\(.conclusion // "-")"' 2>/dev/null || echo "unknown|-")
    case "${st%%|*}" in
      completed) printf '%s' "${st##*|}"; return 0 ;;
      unknown)   printf 'unknown'; return 0 ;;
    esac
    sleep 20
  done
}

# Read the cache state the artefact itself recorded, so intent is checked
# against evidence rather than against what the switch claimed.
recorded_cache() {  # recorded_cache <run-id> <artefact-glob>
  local id="$1" glob="$2" dir f
  dir=$(mktemp -d)
  gh run download "${id}" --dir "${dir}" >/dev/null 2>&1 || { echo "no-artefact"; return; }
  f=$(find "${dir}" -name "${glob}" | head -1)
  [ -z "${f}" ] && { echo "no-artefact"; return; }
  jq -r '.environment.image_verify_cache_enabled // "unrecorded"' "${f}" 2>/dev/null || echo unreadable
}

arm() {  # arm <name> <on|off> <artefact-glob> <field=value>...
  local name="$1" state="$2" glob="$3"; shift 3
  log "── ${name} — cache ${state} ─────────────────────────────────────────"

  echo "▶ setting cache ${state}"
  if ! bash scripts/set-verify-cache.sh "${state}"; then
    echo "✗ ${name}: cache switch failed or did not converge — suite stopped" >&2
    return 1
  fi

  echo "▶ dispatching"
  local id
  if ! id=$(dispatch "$@"); then
    echo "✗ ${name}: dispatch failed or no new run appeared" >&2
    return 1
  fi
  echo "  run ${id} — https://github.com/${GITHUB_REPOSITORY:-JMTeixeira23/DIMEI-k8s-2026}/actions/runs/${id}"

  echo "▶ waiting (nothing else may touch the cluster until this finishes)"
  local concl; concl=$(await "${id}")
  echo "  conclusion: ${concl}"
  [ "${concl}" = success ] || { echo "✗ ${name}: run ${id} ended ${concl}" >&2; return 1; }

  local want="true"; [ "${state}" = off ] && want="false"
  local got; got=$(recorded_cache "${id}" "${glob}")
  echo "▶ artefact says image_verify_cache_enabled=${got} (wanted ${want})"
  if [ "${got}" != "${want}" ]; then
    echo "✗ ${name}: artefact records '${got}', not '${want}' — this is the D34" >&2
    echo "  trap (an unquoted false renders no flag). Suite stopped." >&2
    return 1
  fi
  echo "✓ ${name} complete — run ${id}"
  RESULTS="${RESULTS}${name}\t${id}\t${got}\n"
  return 0
}

RESULTS=""
FAILED=""
for a in ${ARMS}; do
  case "${a}" in
    lat-off) arm "latency matrix"    off "latency-${CLOUD}.json" \
               -f cloud="${CLOUD}" -f iterations="${ITER}" -f size_iterations=0 \
               -f condition_order="baseline audit enforce" || FAILED="${FAILED} ${a}" ;;
    lat-on)  arm "latency matrix"    on  "latency-${CLOUD}.json" \
               -f cloud="${CLOUD}" -f iterations="${ITER}" -f size_iterations=0 \
               -f condition_order="baseline audit enforce" || FAILED="${FAILED} ${a}" ;;
    sz-off)  arm "size matrix"       off "size-latency-${CLOUD}.json" \
               -f cloud="${CLOUD}" -f iterations=0 -f size_iterations="${SIZE_ITER}" || FAILED="${FAILED} ${a}" ;;
    sz-on)   arm "size matrix"       on  "size-latency-${CLOUD}.json" \
               -f cloud="${CLOUD}" -f iterations=0 -f size_iterations="${SIZE_ITER}" || FAILED="${FAILED} ${a}" ;;
    cc-off)  arm "concurrency sweep" off "concurrency-${CLOUD}.json" \
               -f cloud="${CLOUD}" -f iterations=0 -f size_iterations=0 \
               -f concurrency_levels="${CC_LEVELS}" -f concurrency_requests="${CC_REQS}" || FAILED="${FAILED} ${a}" ;;
    cc-on)   arm "concurrency sweep" on  "concurrency-${CLOUD}.json" \
               -f cloud="${CLOUD}" -f iterations=0 -f size_iterations=0 \
               -f concurrency_levels="${CC_LEVELS}" -f concurrency_requests="${CC_REQS}" || FAILED="${FAILED} ${a}" ;;
    *) echo "unknown arm: ${a}" >&2; FAILED="${FAILED} ${a}" ;;
  esac
  [ -n "${FAILED}" ] && break
done

log "════ summary ════"
printf 'arm\trun\tcache\n'
printf '%b' "${RESULTS}"
if [ -n "${FAILED}" ]; then
  echo ""
  echo "✗ stopped at:${FAILED}"
  echo "  Fix the cause, then resume with the remaining arms, e.g."
  echo "    ARMS=\"${FAILED# } ...\" bash scripts/run-perf-suite.sh ${CLOUD}"
  exit 1
fi
echo ""
echo "✓ all arms complete. Next:"
echo "    bash scripts/render-all-tables.sh both"
echo "    python3 scripts/results-manifest.py"
