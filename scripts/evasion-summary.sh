#!/usr/bin/env bash
# scripts/evasion-summary.sh
# Builds the evasion-suite evidence artefact (evasion-results-<cloud>.json and
# .csv, revision item 2.2) from the per-case records written by
# scripts/evasion-lib.sh.
#
# The work is done by scripts/admission-summary.sh, shared with the attack
# simulations and the pipeline's admission tests; this file supplies the suite's
# identity. Deliberately the same renderer: the definition of "matched its
# prediction" must not fork between suites.
#
# One thing the shared renderer does not print is the `control` field — whether
# a matched prediction means the control held or was evaded. It is in the JSON,
# attached by record_evasion, and the dissertation table renders it:
#
#     python3 scripts/attack_table.py --preset evasion evasion-results-aws.json
#
# The CSV carries the shared columns only. The JSON is the artefact of record.
#
# Usage: RESULTS_DIR=/tmp/evasion-results CLOUD=aws bash scripts/evasion-summary.sh

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SUITE_LIB="evasion-lib.sh" \
SUITE_SLUG="evasion-results" \
SUITE_TITLE="Evasion Attempts (revision 2.2)" \
SUITE_NOUN="evasion attempts" \
SUITE_MATCH_PHRASE="behaved as this suite predicted — see the control column, two of them are predicted to get through" \
  exec bash "${HERE}/admission-summary.sh"
