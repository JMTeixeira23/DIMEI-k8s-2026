#!/usr/bin/env bash
# scripts/attack-summary.sh
# Builds the attack-simulation evidence artefact (attack-results-<cloud>.json
# and .csv, the source for Table 6.3) from the per-scenario records written by
# scripts/attack-lib.sh.
#
# The work is done by scripts/admission-summary.sh, shared with the pipeline's
# admission tests; this file supplies the suite's identity. Kept as its own
# entry point because .github/workflows/attack-simulations.yml invokes it by
# name and the artefact it produces is already committed evidence.
#
# Usage: RESULTS_DIR=/tmp/attack-results CLOUD=aws bash scripts/attack-summary.sh

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SUITE_LIB="attack-lib.sh" \
SUITE_SLUG="attack-results" \
SUITE_TITLE="Attack Simulation Results" \
SUITE_NOUN="scenarios" \
  exec bash "${HERE}/admission-summary.sh"
