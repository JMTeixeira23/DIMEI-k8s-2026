#!/usr/bin/env bash
# scripts/render-all-tables.sh [aws|azure]
#
# Regenerates every table the dissertation takes from this repository, from the
# committed artefacts under results/, and writes them to:
#
#     results/TABLES-<cloud>.tex   paste-ready LaTeX
#     results/TABLES-<cloud>.md    the same tables, readable in a diff
#
# One command, so the table set cannot drift from the evidence and so a reader
# can regenerate it without knowing which artefact feeds which table. Every
# table carries a provenance comment naming the run, the URL, the Kyverno image
# and the cache state it came from.
#
# If an artefact is missing the table is skipped with a loud note rather than
# silently omitted — a missing table in the output must be visible, because the
# failure mode this repository cares about is a result that quietly disappears.
set -uo pipefail

CLOUD="${1:-aws}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${HERE}"

# `both` renders ONE table set with a column per cloud, which is the form the
# dissertation actually wants for the security tables — the two clouds are
# compared row by row rather than in two tables a reader has to align by eye.
# No new rendering code is needed: attack_table.py and latency_table.py already
# accept several artefacts and label each column with the cloud it came from.
#
# A cloud with no artefact for a given experiment is dropped from that table
# rather than rendering an empty column, so `both` degrades to the single-cloud
# output while Azure is still being collected.
case "${CLOUD}" in
  both) CLOUDS=(aws azure) ;;
  *)    CLOUDS=("${CLOUD}") ;;
esac

# This script's own shorthand for the two outputs is tex/md; the renderers take
# latex/markdown. Mapped in one place rather than at each of the eight calls.
fmtflag() { case "$1" in tex) echo latex ;; md) echo markdown ;; *) echo "$1" ;; esac; }

TEX="results/TABLES-${CLOUD}.tex"
MD="results/TABLES-${CLOUD}.md"
MISSING=0

one() {  # one <"tex"|"md"> <section title> <command...>
  local fmt="$1" title="$2"; shift 2
  local out
  if ! out=$("$@" --format "$(fmtflag "${fmt}")" 2>&1); then
    printf '%% !! SKIPPED: %s\n%%    %s\n\n' "${title}" "${out//$'\n'/$'\n'%%    }"
    MISSING=$((MISSING + 1))
    return
  fi
  if [ "${fmt}" = md ]; then
    printf '## %s\n\n```\n%s\n```\n\n' "${title}" "${out}"
  else
    printf '%%%% ── %s ──\n%s\n\n' "${title}" "${out}"
  fi
}

# Resolve a glob to ONE path: the match with the highest run id.
#
# Superseded runs are kept in place on purpose — they are the evidence behind
# the currently-written text — so these globs routinely match several
# directories. A plain `${m[0]}` takes the alphabetically first, which is the
# OLDEST run, and that is how the first version of this script rendered the
# fail-open/fail-closed and evasion tables from the superseded v1.11.4 artefacts
# while reporting success. The run id is printed by every table's own footer, so
# the mistake was visible — but a table set that has to be proofread for which
# run it used is not a table set that can be trusted.
#
# Run ids are monotonically increasing, so the numerically largest is the most
# recent. Ties are impossible; ambiguity is reported rather than resolved
# silently.
g() {
  local matches=() m
  for m in $1; do [ -e "$m" ] && matches+=("$m"); done
  [ ${#matches[@]} -gt 0 ] || return
  if [ ${#matches[@]} -gt 1 ]; then
    printf 'note: %d artefacts matched %s; using the highest run id\n' \
      "${#matches[@]}" "$1" >&2
  fi
  # Sort by the first run-id-shaped number in the path, descending.
  printf '%s\n' "${matches[@]}" \
    | while read -r p; do
        printf '%s\t%s\n' "$(printf '%s' "$p" | grep -oE '[0-9]{8,}' | head -1)" "$p"
      done \
    | sort -rn -k1,1 | head -1 | cut -f2- | tr -d '\n'
}

# Resolve one artefact kind for every selected cloud. `@@` stands in for the
# cloud name. Paths containing a glob go through g() so the highest run id wins;
# plain paths are taken only if they exist. Missing entries are dropped, never
# emitted as an empty string — an empty element would become an empty argument
# and the renderer would fail on a file named "".
resolve() {  # resolve <path template using @@ for the cloud>
  local tmpl="$1" c p
  for c in "${CLOUDS[@]}"; do
    p="${tmpl//@@/$c}"
    case "$p" in
      *'*'*) p=$(g "$p") ;;
      *)     [ -f "$p" ] || p="" ;;
    esac
    [ -n "$p" ] && printf '%s\n' "$p"
  done
}

mapfile -t ATTACK    < <(resolve "results/attacks/attack-results-@@.json")
mapfile -t TESTCASE  < <(resolve "results/testcases/testcase-results-@@.json")
mapfile -t EV_MAIN   < <(resolve "results/evasion/@@-*-main/evasion-results-@@.json")
mapfile -t EV_BRANCH < <(resolve "results/evasion/@@-*-branch/evasion-results-@@.json")
mapfile -t FP_OPEN   < <(resolve "results/failure-policy/@@-fail-open-3*/attack-results-@@.json")
mapfile -t FP_CLOSED < <(resolve "results/failure-policy/@@-fail-closed-3*/attack-results-@@.json")
mapfile -t LAT_OFF   < <(resolve "results/latency/@@-*-cache-off/latency-@@.json")
mapfile -t LAT_ON    < <(resolve "results/latency/@@-*-cache-on/latency-@@.json")
mapfile -t SZ_OFF    < <(resolve "results/latency/@@-*-size-cache-off/size-latency-@@.json")
mapfile -t SZ_ON     < <(resolve "results/latency/@@-*-size-cache-on/size-latency-@@.json")
mapfile -t CC_OFF    < <(resolve "results/concurrency/@@-*-cache-off/concurrency-@@.json")
mapfile -t CC_ON     < <(resolve "results/concurrency/@@-*-cache-on/concurrency-@@.json")

# Artefacts collected before the workflow recorded image_verify_cache_enabled
# need the state supplied. The renderer marks such columns as asserted and
# refuses the flag once the artefact records the field itself, so this becomes a
# no-op — and then an error — as soon as these experiments are re-run.
asserted_if_needed() {  # asserted_if_needed <file> -> echoes flags or nothing
  local f="$1"
  [ -n "$f" ] || return
  if [ "$(jq -r '.environment.image_verify_cache_enabled // "unrecorded"' "$f")" = unrecorded ]; then
    printf '%s' "yes"
  fi
}

# Build the --cache-state argument list: one entry per artefact, in the order the
# artefacts are passed. Artefacts that record the field get the literal `auto`,
# which tells latency_table.py to read it rather than take our word for it.
#
# Both halves are necessary. The count must equal the artefact count, and
# supplying a label for an artefact that records its own state is refused — so a
# table mixing the two cannot be rendered with a single uniform policy. Under
# `both` the size and concurrency tables are exactly that mix: the AWS arms were
# collected before the workflow recorded the field, the Azure arms after.
#
# CS_ARGS is emptied and rebuilt on each call; if no artefact needs an assertion
# the array is left empty so the flag is omitted entirely.
CS_ARGS=()
cache_state_args() {  # cache_state_args <label> <file>...   (appends to CS_ARGS)
  local label="$1"; shift
  local f
  for f in "$@"; do
    if [ -n "$(asserted_if_needed "$f")" ]; then
      CS_ARGS+=(--cache-state "${label}")
    else
      CS_ARGS+=(--cache-state auto)
    fi
  done
}

# True when at least one of the given artefacts needs an asserted label.
any_asserted() {  # any_asserted <file>...
  local f
  for f in "$@"; do
    [ -n "$(asserted_if_needed "$f")" ] && return 0
  done
  return 1
}

render() {  # render <fmt> <outfile>
  local fmt="$1"
  {
    if [ "${fmt}" = md ]; then
      echo "# Dissertation tables — ${CLOUD}"
      echo ""
      echo "Generated by \`scripts/render-all-tables.sh ${CLOUD}\` on $(date -u +%Y-%m-%dT%H:%M:%SZ)."
      echo "Do not edit by hand — regenerate."
      echo ""
    else
      echo "%% Dissertation tables — ${CLOUD}"
      echo "%% Generated by scripts/render-all-tables.sh ${CLOUD} on $(date -u +%Y-%m-%dT%H:%M:%SZ)."
      echo "%% Do not edit by hand — regenerate."
      echo "%%"
      echo "%% Requires in the preamble: \\usepackage{booktabs,tabularx}"
      echo ""
    fi

    if [ ${#TESTCASE[@]} -gt 0 ]; then
      one "$fmt" "Table 6.2 — pipeline admission test cases" \
        python3 scripts/attack_table.py --preset testcases "${TESTCASE[@]}"
    fi
    if [ ${#ATTACK[@]} -gt 0 ]; then
      one "$fmt" "Table 6.3 — attack simulations" \
        python3 scripts/attack_table.py "${ATTACK[@]}"
    fi
    if [ ${#FP_OPEN[@]} -gt 0 ] && [ ${#FP_CLOSED[@]} -gt 0 ]; then
      one "$fmt" "Attack simulations under fail-open and fail-closed" \
        python3 scripts/attack_table.py "${FP_OPEN[@]}" "${FP_CLOSED[@]}"
    fi
    if [ ${#EV_MAIN[@]} -gt 0 ]; then
      one "$fmt" "Evasion suite — cases available on main (E1-E3)" \
        python3 scripts/attack_table.py --preset evasion "${EV_MAIN[@]}"
    fi
    if [ ${#EV_BRANCH[@]} -gt 0 ]; then
      one "$fmt" "Evasion suite — branch dispatch (E4)" \
        python3 scripts/attack_table.py --preset evasion "${EV_BRANCH[@]}"
    fi
    if [ ${#LAT_OFF[@]} -gt 0 ] && [ ${#LAT_ON[@]} -gt 0 ]; then
      one "$fmt" "Admission overhead by policy configuration and cache state" \
        python3 scripts/latency_table.py --preset overhead "${LAT_OFF[@]}" "${LAT_ON[@]}"
    fi
    if [ ${#SZ_OFF[@]} -gt 0 ] && [ ${#SZ_ON[@]} -gt 0 ]; then
      CS_ARGS=()
      if any_asserted "${SZ_OFF[@]}" "${SZ_ON[@]}"; then
        cache_state_args "cache off (cold)" "${SZ_OFF[@]}"
        cache_state_args "cache on (warm)"  "${SZ_ON[@]}"
      fi
      one "$fmt" "Admission cost against image size" \
        python3 scripts/latency_table.py --preset size \
          "${CS_ARGS[@]+"${CS_ARGS[@]}"}" "${SZ_OFF[@]}" "${SZ_ON[@]}"
    fi
    if [ ${#CC_OFF[@]} -gt 0 ] && [ ${#CC_ON[@]} -gt 0 ]; then
      CS_ARGS=()
      if any_asserted "${CC_OFF[@]}" "${CC_ON[@]}"; then
        cache_state_args "cache off (cold)" "${CC_OFF[@]}"
        cache_state_args "cache on (warm)"  "${CC_ON[@]}"
      fi
      one "$fmt" "Admission under concurrency" \
        python3 scripts/latency_table.py --preset concurrency \
          "${CS_ARGS[@]+"${CS_ARGS[@]}"}" "${CC_OFF[@]}" "${CC_ON[@]}"
    fi
  }
}

render tex > "${TEX}"
render md  > "${MD}"

# ── Figures, from the same artefacts ────────────────────────────────────────
# In the same command as the tables on purpose: a figure regenerated separately
# from the table beside it is a figure that can disagree with it, which is
# exactly what defects D11 and D18 were.
mkdir -p results/figures
fig() {  # fig <preset> <requests-csv> <out-basename>
  [ -f "$2" ] || return
  if python3 scripts/latency_charts.py --preset "$1" --requests "$2" --out "$3" >/dev/null 2>&1; then
    echo "  $3.png / .pdf"
  else
    echo "  !! figure failed: $3"
    MISSING=$((MISSING + 1))
  fi
}
# Figures stay one-per-cloud even under `both`: a chart with two clouds overlaid
# needs a different design decision than a table with two columns, and silently
# merging them would misrepresent distributions collected on different hardware.
FIGS=""
for c in "${CLOUDS[@]}"; do
  LATOFF_CSV=$(g "results/latency/${c}-*-cache-off/latency-requests-${c}.csv")
  LATON_CSV=$(g "results/latency/${c}-*-cache-on/latency-requests-${c}.csv")
  SZOFF_CSV=$(g "results/latency/${c}-*-size-cache-off/size-requests-${c}.csv")
  SZON_CSV=$(g "results/latency/${c}-*-size-cache-on/size-requests-${c}.csv")
  [ -n "${LATOFF_CSV}" ] && FIGS="${FIGS}$(fig policy "${LATOFF_CSV}" "results/figures/admission-latency-policy-${c}-cache-off")\n"
  [ -n "${LATON_CSV}"  ] && FIGS="${FIGS}$(fig policy "${LATON_CSV}"  "results/figures/admission-latency-policy-${c}-cache-on")\n"
  [ -n "${SZOFF_CSV}"  ] && FIGS="${FIGS}$(fig size   "${SZOFF_CSV}"  "results/figures/admission-latency-size-${c}-cache-off")\n"
  [ -n "${SZON_CSV}"   ] && FIGS="${FIGS}$(fig size   "${SZON_CSV}"   "results/figures/admission-latency-size-${c}-cache-on")\n"
done

echo "Wrote:"
echo "  ${TEX}"
echo "  ${MD}"
[ -n "${FIGS}" ] && printf '%b' "${FIGS}"
if [ "${MISSING}" -gt 0 ]; then
  echo ""
  echo "⚠️  ${MISSING} table(s) could not be rendered — see the '!! SKIPPED' notes."
  echo "    Missing artefacts for ${CLOUD}, or an artefact in an unexpected shape."
fi
