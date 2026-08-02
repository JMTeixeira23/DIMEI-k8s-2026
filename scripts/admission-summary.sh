#!/usr/bin/env bash
# scripts/admission-summary.sh
# Builds an admission-evidence artefact from the per-case records written by
# scripts/admission-lib.sh, and prints a summary derived entirely from those
# records.
#
# Nothing here knows what the "right" answer is. Every line printed and every
# row written comes from what a case observed at admission time. Cases in the
# manifest with no record are emitted as NOT_RUN, so a step that crashed before
# probing is visible rather than absent.
#
# Parameterised by the suite that invokes it:
#   SUITE_LIB    path to the manifest library, relative to scripts/
#   SUITE_SLUG   artefact basename, e.g. attack-results  ->  attack-results-aws.json
#   SUITE_TITLE  human name for the console and job summary
#   SUITE_NOUN   what one row is called, e.g. "scenarios" or "test cases"
#   SUITE_MATCH_PHRASE  what a PASS means, for suites where it is not an
#                       admission outcome (the evasion suite's E2 is decided by
#                       what the kubelet pulled, not by what was admitted)
#
# Outputs (in ${OUT_DIR}, default the current directory):
#   <slug>-<cloud>.json   full evidence artefact, source for the results table
#   <slug>-<cloud>.csv    same rows, flat, one row per case
#
# Exit status is non-zero unless every case in the manifest is PASS.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SUITE_LIB="${SUITE_LIB:?SUITE_LIB is required}"
SUITE_SLUG="${SUITE_SLUG:?SUITE_SLUG is required}"
SUITE_TITLE="${SUITE_TITLE:-Admission results}"
SUITE_NOUN="${SUITE_NOUN:-cases}"
SUITE_MATCH_PHRASE="${SUITE_MATCH_PHRASE:-matched their expected admission outcome}"

# shellcheck source=/dev/null
source "${HERE}/${SUITE_LIB}"

CLOUD="${CLOUD:-unknown}"
OUT_DIR="${OUT_DIR:-.}"
OUT_JSON="${OUT_DIR}/${SUITE_SLUG}-${CLOUD}.json"
OUT_CSV="${OUT_DIR}/${SUITE_SLUG}-${CLOUD}.csv"
PREFLIGHT="${RESULTS_DIR}/_preflight.json"

mkdir -p "${OUT_DIR}"

# ── Collect one record per manifest case, in manifest order ───────────────────
# A missing record means the case did not reach its admission probe. That is
# recorded as NOT_RUN rather than omitted, so the artefact always accounts for
# every case the suite claims to cover.

ORDERED=()
for row in "${SCENARIOS[@]}"; do
  id="${row%%|*}"
  file="${RESULTS_DIR}/${id}.json"
  if [ ! -f "${file}" ]; then
    record_result "${id}" "NOT_RUN" "n/a" \
      "no record written — the step did not reach its admission probe" \
      >/dev/null || true
  fi
  ORDERED+=("${file}")
done

# ── Assemble the artefact ─────────────────────────────────────────────────────

SCENARIOS_JSON="$(jq -s '.' "${ORDERED[@]}")"
PREFLIGHT_JSON='{}'
if [ -f "${PREFLIGHT}" ]; then
  PREFLIGHT_JSON="$(cat "${PREFLIGHT}")"
fi

# Optional diagnostic from the opt-in namespace-scoping probe.
if [ -f "${RESULTS_DIR}/_ns_mechanism.json" ]; then
  PREFLIGHT_JSON="$(jq -s '.[0] + {namespace_mechanism: .[1]}' \
    <(printf '%s' "${PREFLIGHT_JSON}") "${RESULTS_DIR}/_ns_mechanism.json")"
fi

jq -n \
  --argjson scenarios "${SCENARIOS_JSON}" \
  --argjson preflight "${PREFLIGHT_JSON}" \
  --arg cloud       "${CLOUD}" \
  --arg run_id      "${GITHUB_RUN_ID:-local}" \
  --arg run_attempt "${GITHUB_RUN_ATTEMPT:-1}" \
  --arg repository  "${GITHUB_REPOSITORY:-local}" \
  --arg commit      "${GITHUB_SHA:-local}" \
  --arg run_url     "${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-local}/actions/runs/${GITHUB_RUN_ID:-local}" \
  --arg generated   "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{
     run: ({
       cloud:       $cloud,
       run_id:      $run_id,
       run_attempt: $run_attempt,
       repository:  $repository,
       commit:      $commit,
       run_url:     $run_url,
       generated:   $generated
     } + $preflight),
     totals: {
       total: ($scenarios | length),
       pass:  ($scenarios | map(select(.outcome == "PASS"))  | length),
       fail:  ($scenarios | map(select(.outcome == "FAIL"))  | length),
       error: ($scenarios | map(select(.outcome == "ERROR")) | length)
     },
     scenarios: $scenarios
   }' > "${OUT_JSON}"

jq -r '
  ["scenario","title","cloud","run_id","requirements","expected_admission",
   "observed_admission","outcome","expected_rule","observed_rule","image",
   "timestamp","detail","message"],
  (.scenarios[] | [
     .scenario, .title, .cloud, .run_id, (.requirements | join(";")),
     .expected_admission, .observed_admission, .outcome,
     .expected_rule, .observed_rule, .image, .timestamp, .detail, .message
   ])
  | @csv' "${OUT_JSON}" > "${OUT_CSV}"

# ── Console summary ───────────────────────────────────────────────────────────

TOTAL=$(jq -r '.totals.total' "${OUT_JSON}")
PASS=$(jq -r '.totals.pass'   "${OUT_JSON}")
FAIL=$(jq -r '.totals.fail'   "${OUT_JSON}")
ERROR=$(jq -r '.totals.error' "${OUT_JSON}")

echo ""
echo "════════════════════════════════════════════════════════════════"
echo "  ${SUITE_TITLE} — ${CLOUD}"
echo "  Derived from ${RESULTS_DIR}; source artefact: $(basename "${OUT_JSON}")"
echo "════════════════════════════════════════════════════════════════"

jq -r '
  def pad($n): . + (if ($n - length) > 0 then (" " * ($n - length)) else "" end);
  .scenarios[] |
  (if   .outcome == "PASS" then "✅"
   elif .outcome == "FAIL" then "❌"
   else "⚠️" end) as $icon |
  "  \($icon) \(.scenario | pad(6)) " +
  "expected \(.expected_admission | pad(6)) " +
  "observed \(.observed_admission | pad(8)) " +
  "\(.outcome | pad(6))" +
  (if .observed_rule == "" then "" else "  [\(.observed_rule)]" end)
' "${OUT_JSON}"

echo "────────────────────────────────────────────────────────────────"
echo "  ${PASS}/${TOTAL} ${SUITE_NOUN} ${SUITE_MATCH_PHRASE}"
echo "  (${FAIL} unexpected outcome, ${ERROR} not run or errored)"
echo "  Cloud: ${CLOUD} · Run: $(jq -r '.run.run_url' "${OUT_JSON}")"
echo "════════════════════════════════════════════════════════════════"

# ── Job summary (GitHub UI) ───────────────────────────────────────────────────

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "## ${SUITE_TITLE} — ${CLOUD}"
    echo ""
    echo "${PASS}/${TOTAL} ${SUITE_NOUN} ${SUITE_MATCH_PHRASE} "
    echo "(${FAIL} unexpected, ${ERROR} not run or errored)."
    echo ""
    echo "| Case | Requirements | Expected | Observed | Blocked by | Outcome |"
    echo "|---|---|---|---|---|---|"
    jq -r '.scenarios[] |
      "| \(.scenario) — \(.title) | \(.requirements | join(", ")) " +
      "| \(.expected_admission) | \(.observed_admission) " +
      "| \(if .observed_rule == "" then "—" else .observed_rule end) " +
      "| \(.outcome) |"' "${OUT_JSON}"
    echo ""
    echo "Artefact: \`$(basename "${OUT_JSON}")\` / \`$(basename "${OUT_CSV}")\` (job artifacts)."
  } >> "${GITHUB_STEP_SUMMARY}"
fi

# ── Gate ──────────────────────────────────────────────────────────────────────

if [ "${PASS}" != "${TOTAL}" ]; then
  echo ""
  echo "Result: NOT all ${SUITE_NOUN} behaved as expected — see the table above."
  exit 1
fi

echo ""
echo "Result: all ${TOTAL} ${SUITE_NOUN} behaved as expected."
