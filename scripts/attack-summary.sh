#!/usr/bin/env bash
# scripts/attack-summary.sh
# Builds the attack-simulation evidence artefact from the per-scenario records
# written by scripts/attack-lib.sh, and prints a summary derived entirely from
# those records.
#
# Nothing here knows what the "right" answer is. Every line printed and every
# row written comes from what a scenario observed at admission time. Scenarios
# in the manifest with no record are emitted as NOT_RUN.
#
# Outputs (in ${OUT_DIR}, default the current directory):
#   attack-results-<cloud>.json   full evidence artefact, source for Table 6.3
#   attack-results-<cloud>.csv    same scenarios, flat, one row per scenario
#
# Exit status is non-zero unless every scenario in the manifest is PASS.
#
# Usage: RESULTS_DIR=/tmp/attack-results CLOUD=aws bash scripts/attack-summary.sh

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/attack-lib.sh
source "${HERE}/attack-lib.sh"

CLOUD="${CLOUD:-unknown}"
OUT_DIR="${OUT_DIR:-.}"
OUT_JSON="${OUT_DIR}/attack-results-${CLOUD}.json"
OUT_CSV="${OUT_DIR}/attack-results-${CLOUD}.csv"
PREFLIGHT="${RESULTS_DIR}/_preflight.json"

mkdir -p "${OUT_DIR}"

# ── Collect one record per manifest scenario, in manifest order ───────────────
# A missing record means the scenario did not reach its admission probe. That is
# recorded as NOT_RUN rather than omitted, so the artefact always accounts for
# every scenario the suite claims to cover.

ORDERED=()
for row in "${SCENARIOS[@]}"; do
  id="${row%%|*}"
  file="${RESULTS_DIR}/${id}.json"
  if [ ! -f "${file}" ]; then
    record_result "${id}" "NOT_RUN" "n/a" \
      "no record written — the scenario step did not reach its admission probe" \
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
echo "  Attack Simulation Results — ${CLOUD}"
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
echo "  ${PASS}/${TOTAL} scenarios matched their expected admission outcome"
echo "  (${FAIL} unexpected outcome, ${ERROR} not run or errored)"
echo "  Cloud: ${CLOUD} · Run: $(jq -r '.run.run_url' "${OUT_JSON}")"
echo "════════════════════════════════════════════════════════════════"

# ── Job summary (GitHub UI) ───────────────────────────────────────────────────

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "## Attack simulations — ${CLOUD}"
    echo ""
    echo "${PASS}/${TOTAL} scenarios matched their expected admission outcome "
    echo "(${FAIL} unexpected, ${ERROR} not run or errored)."
    echo ""
    echo "| Scenario | Requirements | Expected | Observed | Blocked by | Outcome |"
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
  echo "Result: NOT all scenarios behaved as expected — see the table above."
  exit 1
fi

echo ""
echo "Result: all ${TOTAL} scenarios behaved as expected."
