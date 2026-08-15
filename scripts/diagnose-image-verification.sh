#!/usr/bin/env bash
# diagnose-image-verification.sh — why did Kyverno deny an image that Cosign verified?
#
# Written for defect D29: the first pipeline run on Cosign v3.1.2 had the
# pipeline's own `cosign verify` pass and Kyverno v1.18.2 deny the same image on
# all three policies. Cosign 3 changed three defaults at once (protobuf bundle
# format, OCI 1.1 referring artifacts, TUF-provided service URLs), so "it broke"
# is not a diagnosis — this script separates the candidates.
#
# It CHANGES NOTHING. Read-only against the registry and the cluster.
#
#   Usage:  bash scripts/diagnose-image-verification.sh <image-ref-with-digest>
#
#   e.g.    bash scripts/diagnose-image-verification.sh \
#             812982728774.dkr.ecr.eu-west-1.amazonaws.com/supply-chain-demo@sha256:4070e3...
#
# Requires: cosign, crane (optional), kubectl with cluster access, jq.
# Writes a JSON artefact to $OUT (default /tmp/verification-diagnosis.json).

set -uo pipefail

IMAGE_REF="${1:-}"
OUT="${OUT:-/tmp/verification-diagnosis.json}"

if [ -z "${IMAGE_REF}" ]; then
  echo "usage: $0 <image-ref@sha256:...>" >&2
  exit 2
fi
case "${IMAGE_REF}" in
  *@sha256:*) : ;;
  *) echo "ERROR: pass a digest reference, not a tag. Got: ${IMAGE_REF}" >&2; exit 2 ;;
esac

REPO_PART="${IMAGE_REF%@*}"

# Reject a reference the registry cannot parse, rather than probing it and
# reporting "absent". The first run of this script was given
# `…/DIMEI-k8s-2026@sha256:…` — the repository is `…/supply-chain/hello-world`
# — and dutifully reported both legacy tags ABSENT. They were not absent; the
# path was illegal. OCI repository names are lowercase only, so this is
# checkable up front, and a diagnostic that can report a false absence is worse
# than one that refuses to run.
REPO_NAME="${REPO_PART#*/}"
if printf '%s' "${REPO_NAME}" | grep -q '[A-Z]'; then
  echo "ERROR: '${REPO_NAME}' is not a legal OCI repository name — uppercase is" >&2
  echo "       not permitted, so no probe against it can succeed and an 'absent'" >&2
  echo "       result would be meaningless. Check the reference." >&2
  echo "       Hint: the repository is in the Kyverno log line, as image=<ref>." >&2
  exit 2
fi

DIGEST="${IMAGE_REF#*@}"
SIG_TAG="${REPO_PART}:${DIGEST/:/-}.sig"
ATT_TAG="${REPO_PART}:${DIGEST/:/-}.att"

hdr() { printf '\n\033[1m══ %s ══\033[0m\n' "$1"; }
note() { printf '   %s\n' "$1"; }

# Collected facts, appended as jq -n args at the end. Nothing here is
# interpreted into a conclusion: the script reports what it found and lists the
# candidates the findings are consistent with.
cosign_version="$(cosign version 2>/dev/null | grep -i 'GitVersion' | awk '{print $2}')"
[ -z "${cosign_version}" ] && cosign_version="$(cosign version 2>&1 | tail -1)"

hdr "0. What is asking, and what is answering"
note "image     : ${IMAGE_REF}"
note "cosign    : ${cosign_version:-unknown}"
kyverno_image="$(kubectl get deployment kyverno-admission-controller -n kyverno \
  -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null)"
note "kyverno   : ${kyverno_image:-<no cluster access>}"

# ── 1. Where did cosign put the artefacts? ───────────────────────────────────
# Hypothesis A is that cosign 3 wrote an OCI 1.1 referring artifact and Kyverno
# looked at the legacy `sha256-<digest>.sig` tag. If the legacy tags are absent
# and the referrers list is populated, A is live.

hdr "1. Storage location — legacy tags vs OCI 1.1 referrers"

legacy_sig="absent"; legacy_att="absent"
if crane manifest "${SIG_TAG}" >/tmp/d29-sig.json 2>/dev/null; then
  legacy_sig="present"
  note "legacy signature tag PRESENT : ${SIG_TAG}"
  note "  mediaType: $(jq -r '.mediaType // "?"' /tmp/d29-sig.json)"
  note "  layers   : $(jq -r '[.layers[].mediaType] | join(", ")' /tmp/d29-sig.json 2>/dev/null)"
else
  note "legacy signature tag ABSENT  : ${SIG_TAG}"
fi

if crane manifest "${ATT_TAG}" >/tmp/d29-att.json 2>/dev/null; then
  legacy_att="present"
  note "legacy attestation tag PRESENT: ${ATT_TAG}"
  note "  layers   : $(jq -r '[.layers[].mediaType] | join(", ")' /tmp/d29-att.json 2>/dev/null)"
else
  note "legacy attestation tag ABSENT : ${ATT_TAG}"
fi

referrer_count=0; referrer_types=""
if crane referrers "${IMAGE_REF}" >/tmp/d29-ref.json 2>/dev/null; then
  referrer_count="$(jq -r '.manifests | length' /tmp/d29-ref.json 2>/dev/null || echo 0)"
  referrer_types="$(jq -r '[.manifests[].artifactType] | join(", ")' /tmp/d29-ref.json 2>/dev/null)"
  note "OCI 1.1 referrers: ${referrer_count} — ${referrer_types:-none}"
else
  note "OCI 1.1 referrers: could not be listed (crane missing, or registry has no Referrers API)"
fi

hdr "1b. cosign's own view of the tree"
cosign tree "${IMAGE_REF}" 2>&1 | sed 's/^/   /'

# ── 2. Does cosign verify it, from here? ─────────────────────────────────────
# The pipeline already proved it does in CI. Repeating it here separates
# "cosign can verify this at all" from "cosign could verify it in that job".

hdr "2. Independent cosign verification"
CERT_ID_RE="${CERT_ID_RE:-https://github.com/JMTeixeira23/DIMEI-k8s-2026.*}"
CERT_ISSUER="${CERT_ISSUER:-https://token.actions.githubusercontent.com}"
cosign_verify="fail"
if cosign verify --certificate-identity-regexp "${CERT_ID_RE}" \
     --certificate-oidc-issuer "${CERT_ISSUER}" "${IMAGE_REF}" >/tmp/d29-verify.json 2>/tmp/d29-verify.err; then
  cosign_verify="pass"
  note "cosign verify: PASS"
else
  note "cosign verify: FAIL"
  sed 's/^/     /' /tmp/d29-verify.err | head -10
fi

# ── 3. Which transparency log holds the entry? ───────────────────────────────
# Hypothesis B. Cosign 3 fetches service URLs from the TUF signing config by
# default, which can place the entry in a log the policy does not name. The
# policies pin rekor.url: https://rekor.sigstore.dev.

hdr "3. Transparency log the signature actually points at"
tlog_urls="$(jq -r '.[]?.optional?.Bundle?.Payload?.logID? // empty' /tmp/d29-verify.json 2>/dev/null | sort -u | tr '\n' ' ')"
note "logID(s) in the verification output: ${tlog_urls:-<none recorded>}"
note "policy pins: https://rekor.sigstore.dev (read from policies/verify-image-signature.yaml)"
grep -h 'rekor' -A2 policies/verify-*.yaml 2>/dev/null | grep -i 'url' | sort -u | sed 's/^/     /'

# ── 4. What did Kyverno actually say? ────────────────────────────────────────
# The admission message is generic ("unverified image"). The controller log
# carries the reason, and the reason is the whole point of this exercise.

hdr "4. Kyverno's own account of the failure"
kyverno_log="<no cluster access>"
if [ -n "${kyverno_image}" ]; then
  kyverno_log="$(kubectl logs -n kyverno -l app.kubernetes.io/component=admission-controller \
    --tail=400 --since=30m 2>/dev/null \
    | grep -iE 'verif|signature|attestation|rekor|bundle|referrer|tlog|cosign|error' \
    | tail -40)"
  if [ -n "${kyverno_log}" ]; then
    printf '%s\n' "${kyverno_log}" | sed 's/^/   /'
  else
    note "nothing matched in the last 400 lines / 30 minutes."
    note "Re-run the denial, then run this script again within 30 minutes."
    kyverno_log="<no matching lines>"
  fi
else
  note "kubectl has no access to the cluster; skipped."
fi

# ── 5. Record, without concluding ────────────────────────────────────────────

jq -n \
  --arg image "${IMAGE_REF}" \
  --arg cosign "${cosign_version}" \
  --arg kyverno "${kyverno_image}" \
  --arg legacy_sig "${legacy_sig}" \
  --arg legacy_att "${legacy_att}" \
  --arg referrers "${referrer_count}" \
  --arg referrer_types "${referrer_types}" \
  --arg cosign_verify "${cosign_verify}" \
  --arg tlog "${tlog_urls}" \
  --arg klog "${kyverno_log}" \
  --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{
     generated: $ts,
     defect: "D29",
     question: "Cosign verifies the image; Kyverno denies it. Which of the three Cosign-3 default changes is responsible?",
     observed: {
       image: $image,
       cosign_version: $cosign,
       kyverno_image: $kyverno,
       legacy_signature_tag: $legacy_sig,
       legacy_attestation_tag: $legacy_att,
       oci_1_1_referrer_count: ($referrers | tonumber? // 0),
       oci_1_1_referrer_types: $referrer_types,
       independent_cosign_verify: $cosign_verify,
       tlog_ids: $tlog,
       kyverno_admission_controller_log: $klog
     },
     reading: {
       storage_mismatch:
         (if $legacy_sig == "absent" and (($referrers | tonumber? // 0) > 0)
          then "CONSISTENT — cosign wrote OCI 1.1 referrers and nothing at the legacy tag Kyverno reads"
          elif $legacy_sig == "present"
          then "NOT the cause — the legacy tag Kyverno reads does exist"
          else "INCONCLUSIVE — neither location could be read from here" end),
       caveat: "These readings say which hypotheses the observations are consistent with. They are not a diagnosis. The Kyverno log line is the authority; everything else is circumstantial."
     }
   }' > "${OUT}"

hdr "Recorded"
note "artefact: ${OUT}"
note "$(jq -r '.reading.storage_mismatch' "${OUT}")"
echo ""
