#!/usr/bin/env bash
# scripts/slsa-l2-evidence.sh
# Records what the SLSA Build Level 2 step actually produced, as a JSON artefact.
#
# Revision item 3.1. The L2 provenance is generated and signed by the build
# platform (actions/attest-build-provenance) rather than by the build itself,
# which is the L1 → L2 distinction. This script records the observable facts and
# keeps them separate from the interpretation:
#
#   observed{}  what was measured — the attestation exists, verifies, its
#               predicate type, its certificate identity, its storage location
#   claim{}     what those facts are taken to mean, and on what basis
#
# Nothing here decides that the build "is L2". It records that a platform-signed
# in-toto provenance statement of the SLSA v1.0 predicate type exists and
# verifies, and states plainly that the level is an interpretation of that.
#
# A failed or skipped L2 step is recorded as such, never omitted. The whole point
# of the design is that L2 cannot break L1, which means an L2 failure has to be
# visible rather than fatal.
#
# Usage (from the pipeline):
#   OUT=slsa-l2-aws.json \
#   L2_ENABLED=true L2_OUTCOME=success \
#   BUNDLE_PATH=/tmp/attestation.jsonl \
#   IMAGE_REF=<registry>/<repo>@sha256:... \
#   SUBJECT_DIGEST=sha256:... \
#     bash scripts/slsa-l2-evidence.sh

set -uo pipefail

OUT="${OUT:-slsa-l2-${CLOUD:-unknown}.json}"
L2_ENABLED="${L2_ENABLED:-false}"
L2_OUTCOME="${L2_OUTCOME:-skipped}"
BUNDLE_PATH="${BUNDLE_PATH:-}"
IMAGE_REF="${IMAGE_REF:-}"
SUBJECT_DIGEST="${SUBJECT_DIGEST:-}"

flatten() { printf '%s' "${1:-}" | tr '\n\r\t' '   ' | tr -s ' ' | sed 's/^ *//; s/ *$//' | cut -c1-1200; }

# ── What the bundle says, if there is one ────────────────────────────────────
# Read from the file the action wrote rather than from anything this script
# assumes about it. Absent or unparseable is recorded as such.

PREDICATE_TYPE=""
BUILDER_ID=""
BUNDLE_SUBJECT=""
BUNDLE_PRESENT=false

if [ -n "${BUNDLE_PATH}" ] && [ -s "${BUNDLE_PATH}" ]; then
  BUNDLE_PRESENT=true
  # The bundle is JSON (or JSON lines); the DSSE payload inside is base64.
  PAYLOAD=$(head -1 "${BUNDLE_PATH}" | jq -r '.dsseEnvelope.payload // .payload // empty' 2>/dev/null || true)
  if [ -n "${PAYLOAD}" ]; then
    STATEMENT=$(printf '%s' "${PAYLOAD}" | base64 -d 2>/dev/null || true)
    if [ -n "${STATEMENT}" ]; then
      PREDICATE_TYPE=$(printf '%s' "${STATEMENT}" | jq -r '.predicateType // empty' 2>/dev/null || true)
      BUILDER_ID=$(printf '%s' "${STATEMENT}" | jq -r '.predicate.runDetails.builder.id // .predicate.builder.id // empty' 2>/dev/null || true)
      BUNDLE_SUBJECT=$(printf '%s' "${STATEMENT}" | jq -r '[.subject[]? | "\(.name)@sha256:\(.digest.sha256 // "")"] | join(" ")' 2>/dev/null || true)
    fi
  fi
fi

# ── Does it verify, independently of the action that produced it? ────────────

VERIFY_OUTPUT=""
VERIFY_OK=false
if [ "${L2_OUTCOME}" = "success" ] && [ -n "${IMAGE_REF}" ] && command -v gh >/dev/null 2>&1; then
  if VERIFY_OUTPUT=$(gh attestation verify "oci://${IMAGE_REF}" \
        --repo "${GITHUB_REPOSITORY:-}" 2>&1); then
    VERIFY_OK=true
  fi
fi

# ── The record ───────────────────────────────────────────────────────────────

jq -n \
  --arg cloud            "${CLOUD:-unknown}" \
  --arg run_id           "${GITHUB_RUN_ID:-local}" \
  --arg repository       "${GITHUB_REPOSITORY:-local}" \
  --arg commit           "${GITHUB_SHA:-local}" \
  --arg run_url          "${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-local}/actions/runs/${GITHUB_RUN_ID:-local}" \
  --arg generated        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --argjson enabled      "${L2_ENABLED}" \
  --arg outcome          "${L2_OUTCOME}" \
  --arg image            "${IMAGE_REF}" \
  --arg subject_digest   "${SUBJECT_DIGEST}" \
  --argjson bundle_present "${BUNDLE_PRESENT}" \
  --arg predicate_type   "${PREDICATE_TYPE}" \
  --arg builder_id       "${BUILDER_ID}" \
  --arg bundle_subject   "${BUNDLE_SUBJECT}" \
  --argjson verified     "${VERIFY_OK}" \
  --arg verify_output    "$(flatten "${VERIFY_OUTPUT}")" \
  '{
     run: {
       cloud: $cloud, run_id: $run_id, repository: $repository,
       commit: $commit, run_url: $run_url, generated: $generated
     },
     observed: {
       step_enabled:      $enabled,
       step_outcome:      $outcome,
       image:             $image,
       subject_digest:    $subject_digest,
       bundle_present:    $bundle_present,
       predicate_type:    $predicate_type,
       builder_id:        $builder_id,
       bundle_subject:    $bundle_subject,
       verifies_independently: $verified,
       verify_output:     $verify_output
     },
     claim: {
       level: (if $verified and ($predicate_type | startswith("https://slsa.dev/provenance/"))
               then "SLSA v1.0 Build Level 2"
               else "not established by this run" end),
       basis: "provenance generated and signed by the hosted build platform rather than by the build, of the SLSA v1.0 predicate type, verifying independently of the step that produced it",
       caveat: "the level is an interpretation of the facts in observed{}, not itself a measurement. The admission policy does not verify this attestation — it verifies the Cosign-stored one; see changes.md section 15."
     },
     l1_path: {
       note: "unaffected by this step. gen_slsa_provenance.py and the cosign attest steps are unchanged, and the admission policy reads the Cosign attestation tag. Setting SLSA_L2=false removes this step and nothing else."
     }
   }' > "${OUT}"

echo "── SLSA L2 evidence ──"
jq -r '
  "  enabled          : \(.observed.step_enabled)",
  "  outcome          : \(.observed.step_outcome)",
  "  bundle present   : \(.observed.bundle_present)",
  "  predicate type   : \(.observed.predicate_type // "-")",
  "  builder id       : \(.observed.builder_id // "-")",
  "  verifies         : \(.observed.verifies_independently)",
  "  claim            : \(.claim.level)"
' "${OUT}"

# Never fails the job. L2 is additive; a failure here is a recorded outcome, not
# a reason to fail a pipeline whose L1 guarantees are intact.
exit 0
