#!/usr/bin/env bash
# scripts/attack-lib.sh
# The attack-simulation suite for .github/workflows/attack-simulations.yml.
#
# This file is the manifest — what the suite claims to cover. The machinery that
# probes admission and records evidence lives in scripts/admission-lib.sh and is
# shared with the pipeline's admission tests, so the two suites cannot drift
# apart in how they define a pass.
#
# Design rule, enforced by that shared machinery: no result in this suite is
# ever written by hand. Every scenario records what it actually observed as a
# JSON document under ${RESULTS_DIR}. The workflow summary, the uploaded
# artefact and Table 6.3 of the dissertation are all derived from those records.
# A scenario that does not run leaves no record and is reported as NOT_RUN — it
# cannot be silently reported as passing.
#
# Sourced, not executed:  source scripts/attack-lib.sh
#
# Requires: bash 4+, jq, kubectl, docker (for the image helpers).

# shellcheck disable=SC2034  # several vars are consumed by the caller

# ── Scenario manifest ─────────────────────────────────────────────────────────
# The single source of truth for what this suite claims to cover. The summary
# iterates this list, so a scenario that is deleted from the workflow shows up
# as NOT_RUN rather than disappearing from the results — which is exactly the
# failure mode this rewrite exists to prevent.
#
# Fields: id | title | security requirements | expected outcome | expected rule
SCENARIOS=(
  "A1|Unsigned image from an unapproved external registry (alpine:latest, docker.io)|SR-05|DENY|verify-image-signature/block-unapproved-registry"
  "A2|Valid Cosign signature from the wrong identity (attacker-held local key)|SR-01|DENY|verify-image-signature/check-image-signature"
  "A3|Tag redirected to unsigned content after signing (pre-admission TOCTOU)|SR-02|DENY|verify-image-signature/check-image-signature"
  "A4|Signed, provenance attested, CycloneDX SBOM attestation omitted|SR-03|DENY|verify-sbom-cyclonedx/check-sbom-cyclonedx"
  "A5|Signed, SBOM attested, SLSA provenance attestation omitted|SR-04|DENY|verify-slsa-provenance/check-slsa-provenance"
  "A6|Unsigned image pushed to the approved registry (insider build)|SR-01,SR-06|DENY|verify-image-signature/check-image-signature"
  "TC-NS|Namespace scoping: the A6 unsigned image in the default namespace|SR-07|ADMIT|none (policy match scope)"
)

# Policy/rule pairs that can appear in a Kyverno denial message. Used to derive
# which rule actually blocked a deployment, instead of assuming it was the one
# the scenario intended to exercise.
KNOWN_RULES=(
  "verify-image-signature/block-unapproved-registry"
  "verify-image-signature/check-image-signature"
  "verify-sbom-cyclonedx/check-sbom-cyclonedx"
  "verify-slsa-provenance/check-slsa-provenance"
)

RESULTS_DIR="${RESULTS_DIR:-/tmp/attack-results}"

# shellcheck source=scripts/admission-lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/admission-lib.sh"

# ── Suite-specific fixtures ───────────────────────────────────────────────────

# build_unsigned_image <image:tag> <label>
# The unsigned artefact used by A6 and re-used by TC-NS. Kept here so both
# scenarios provably deploy the same image and cannot drift apart.
build_unsigned_image() {
  local image="$1" label="$2"
  docker build -t "${image}" - <<DOCKERFILE
FROM alpine:3.19
LABEL threat="${label}"
CMD ["sh", "-c", "echo ${label}"]
DOCKERFILE
}
