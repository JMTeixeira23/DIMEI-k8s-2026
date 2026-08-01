#!/usr/bin/env bash
# scripts/testcase-summary.sh
# Builds the pipeline admission-test artefact (testcase-results-<cloud>.json and
# .csv, the source for Table 6.2) from the per-case records written by
# scripts/testcase-lib.sh.
#
# Replaces the hardcoded `echo` block that used to serve as the pipeline's
# summary. That block printed the same five lines whatever the cluster did, so
# Table 6.2 was a transcription of the workflow's intentions rather than of its
# observations.
#
# Usage: RESULTS_DIR=/tmp/testcase-results CLOUD=aws bash scripts/testcase-summary.sh

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SUITE_LIB="testcase-lib.sh" \
SUITE_SLUG="testcase-results" \
SUITE_TITLE="Pipeline Admission Tests" \
SUITE_NOUN="test cases" \
  exec bash "${HERE}/admission-summary.sh"
