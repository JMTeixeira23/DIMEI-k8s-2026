#!/usr/bin/env bash
# scripts/testcase-lib.sh
# The admission test suite for .github/workflows/supply-chain-pipeline.yml —
# TC-01 … TC-05, the source of Table 6.2.
#
# These test cases were always real and always ran; what was not real was the
# report. The pipeline's `Summary` step printed "TC-01: signed image admitted"
# and four lines like it from a hardcoded `echo` block under `if: always()`, so
# the summary said the same thing whatever the cluster did. Table 6.2 rested on
# that block. This suite replaces it with records derived from what each probe
# observed, the same way the attack simulations were fixed.
#
# The machinery lives in scripts/admission-lib.sh, shared with the attack suite,
# so both tables come from one definition of what a pass is.
#
# Sourced, not executed:  source scripts/testcase-lib.sh

# shellcheck disable=SC2034  # several vars are consumed by the caller

# ── Test case manifest ────────────────────────────────────────────────────────
# Fields: id | title | security requirements | expected outcome | expected rule
#
# TC-01 is the positive control and the only ADMIT case in the pipeline: it
# proves the policies do not block compliant work. Without it, a cluster that
# denied everything would score four out of five.
#
# TC-02 and TC-03 are deliberately the same test against two different public
# images. Report them as one finding with two instances, not as two independent
# results — they exercise one rule by one mechanism.
SCENARIOS=(
  "TC-01|Pipeline-built image: signed, SBOM-attested and provenance-attested, deployed by digest|SR-01,SR-03,SR-04|ADMIT|none (fully compliant)"
  "TC-02|Public image from an unapproved registry (nginx:latest, docker.io)|SR-05|DENY|verify-image-signature/block-unapproved-registry"
  "TC-03|Public image from an unapproved registry (alpine:latest, docker.io)|SR-05|DENY|verify-image-signature/block-unapproved-registry"
  "TC-04|Unsigned image pushed to the approved registry|SR-01,SR-06|DENY|verify-image-signature/check-image-signature"
  "TC-05|Namespace scoping: the TC-04 unsigned image in the default namespace|SR-07|ADMIT|none (policy match scope)"
)

KNOWN_RULES=(
  "verify-image-signature/block-unapproved-registry"
  "verify-image-signature/check-image-signature"
  "verify-sbom-cyclonedx/check-sbom-cyclonedx"
  "verify-slsa-provenance/check-slsa-provenance"
)

RESULTS_DIR="${RESULTS_DIR:-/tmp/testcase-results}"

# shellcheck source=scripts/admission-lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/admission-lib.sh"
