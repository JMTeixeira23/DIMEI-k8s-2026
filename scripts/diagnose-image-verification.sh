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

# ── Preflight: refuse to report an absence this script cannot distinguish from
# an inability to look. The first run of this script reported both legacy tags
# "ABSENT" when the reference was illegal, and "referrers: could not be listed"
# when crane simply was not installed. Both read as findings. Neither was one.
# A diagnostic that cannot tell "not there" from "did not look" is worse than
# no diagnostic, because its output gets believed.
preflight_fail=0
if ! command -v crane >/dev/null 2>&1; then
  echo "ERROR: crane is not installed." >&2
  echo "       Without it this script cannot read the legacy tags or the OCI 1.1" >&2
  echo "       referrers, and would report both as absent when it simply could" >&2
  echo "       not look. Storage location is the whole question here." >&2
  preflight_fail=1
fi
if ! command -v cosign >/dev/null 2>&1; then
  echo "ERROR: cosign is not installed." >&2
  preflight_fail=1
else
  _cv="$(cosign version 2>/dev/null | grep -i GitVersion | awk '{print $2}')"
  case "${_cv}" in
    v3.*) : ;;
    "")   echo "WARNING: could not determine the cosign version." >&2 ;;
    *)    echo "ERROR: local cosign is ${_cv}, but the pipeline signs with a 3.x." >&2
          echo "       Cosign 2 cannot read the bundle format and referrer layout" >&2
          echo "       that Cosign 3 writes, so a 'verify: FAIL' from this script" >&2
          echo "       would say nothing about what Kyverno sees." >&2
          preflight_fail=1 ;;
  esac
fi
if [ "${preflight_fail}" = 1 ]; then
  echo "" >&2
  echo "  Fix with:  bash scripts/local/install-tools.sh" >&2
  echo "             export PATH=\"\${PATH}:\${HOME}/.local/bin\"" >&2
  echo "  Refusing to run rather than produce a result that reads as evidence." >&2
  exit 3
fi

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

# ── Never report an absence that might be a refusal ──────────────────────────
# Third time this bit: an illegal reference, then a missing crane, then an
# expired ECR token, each rendered as "ABSENT" — a finding-shaped string for a
# question that was never asked. `absent` and `denied` are different answers and
# this function keeps them different. A 404/MANIFEST_UNKNOWN means the artefact
# is not there; a 401/403/DENIED means we were not allowed to look, and the only
# honest output then is to stop.
probe_manifest() {  # probe_manifest <ref> <outfile> ; echoes present|absent|denied|error
  local ref="$1" out="$2" err
  if crane manifest "${ref}" >"${out}" 2>/tmp/d29-err; then
    echo present; return
  fi
  err="$(tr '[:upper:]' '[:lower:]' < /tmp/d29-err)"
  case "${err}" in
    *denied*|*unauthorized*|*authentication*|*"401"*|*"403"*|*"token has expired"*) echo denied ;;
    *manifest_unknown*|*name_unknown*|*not_found*|*"404"*)                          echo absent ;;
    *)                                                                              echo error  ;;
  esac
}

# The image itself must be readable, or nothing below means anything.
registry_access="$(probe_manifest "${IMAGE_REF}" /tmp/d29-img.json)"
if [ "${registry_access}" != "present" ]; then
  note "cannot read the image manifest itself: ${registry_access}"
  sed 's/^/     /' /tmp/d29-err | head -4
  echo ""
  if [ "${registry_access}" = "denied" ]; then
    echo "  ERROR: the registry refused the request — the credentials are missing" >&2
    echo "         or expired. Every probe below would report 'absent' when the" >&2
    echo "         truth is 'not allowed to look', which is exactly the false" >&2
    echo "         finding this script exists to avoid. Re-authenticate:" >&2
    echo "" >&2
    echo "           aws ecr get-login-password --region ${IMAGE_REF#*.dkr.ecr.} \\" >&2
    echo "             | sed 's/\\.amazonaws\\.com.*//' >/dev/null  # region is in the host" >&2
    echo "           aws ecr get-login-password --region <region> \\" >&2
    echo "             | crane auth login --username AWS --password-stdin \\" >&2
    echo "                 ${REPO_PART%%/*}" >&2
  else
    echo "  ERROR: the image manifest could not be read (${registry_access})." >&2
  fi
  exit 4
fi
note "image manifest readable — the registry is answering us"

legacy_sig="$(probe_manifest "${SIG_TAG}" /tmp/d29-sig.json)"
case "${legacy_sig}" in
  present)
    note "legacy signature tag PRESENT : ${SIG_TAG}"
    note "  mediaType: $(jq -r '.mediaType // "?"' /tmp/d29-sig.json)"
    note "  layers   : $(jq -r '[.layers[].mediaType] | join(", ")' /tmp/d29-sig.json 2>/dev/null)"
    ;;
  absent)  note "legacy signature tag ABSENT  : ${SIG_TAG}  (404 — genuinely not there)" ;;
  *)       note "legacy signature tag UNKNOWN : ${legacy_sig} — NOT a finding" ;;
esac

legacy_att="$(probe_manifest "${ATT_TAG}" /tmp/d29-att.json)"
case "${legacy_att}" in
  present)
    note "legacy attestation tag PRESENT: ${ATT_TAG}"
    note "  layers   : $(jq -r '[.layers[].mediaType] | join(", ")' /tmp/d29-att.json 2>/dev/null)"
    ;;
  absent)  note "legacy attestation tag ABSENT : ${ATT_TAG}  (404 — genuinely not there)" ;;
  *)       note "legacy attestation tag UNKNOWN: ${legacy_att} — NOT a finding" ;;
esac

referrer_count=0; referrer_types=""; referrer_state="unknown"
if crane referrers "${IMAGE_REF}" >/tmp/d29-ref.json 2>/tmp/d29-referr; then
  referrer_state="listed"
  referrer_count="$(jq -r '.manifests | length' /tmp/d29-ref.json 2>/dev/null || echo 0)"
  referrer_types="$(jq -r '[.manifests[].artifactType] | join(", ")' /tmp/d29-ref.json 2>/dev/null)"
  note "OCI 1.1 referrers: ${referrer_count} — ${referrer_types:-none}"
else
  referrer_state="could-not-list"
  note "OCI 1.1 referrers: COULD NOT LIST — this is not the same as 'none'"
  sed 's/^/     /' /tmp/d29-referr | head -3
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
  --arg referrer_state "${referrer_state}" \
  --arg registry_access "${registry_access}" \
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
       registry_access: $registry_access,
       oci_1_1_referrer_listing: $referrer_state,
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
          then "NOT a storage problem — the legacy tag Kyverno reads does exist; compare its layer mediaTypes against what Kyverno expects, because the question is then FORMAT, not location"
          elif $legacy_sig == "absent" and $referrer_state != "listed"
          then "INCOMPLETE — the legacy tag is genuinely absent (404), but the referrers could not be listed, so where cosign DID write is still unknown"
          elif $legacy_sig == "absent"
          then "PUZZLE — legacy tag absent and zero referrers, yet cosign verified this image in CI. Something is being read from a third place; do not guess"
          else "NOT ESTABLISHED — the legacy tag could not be read (\($legacy_sig)). This is not evidence of absence" end),
       caveat: "These readings say which hypotheses the observations are consistent with. They are not a diagnosis. The Kyverno log line is the authority; everything else is circumstantial."
     }
   }' > "${OUT}"

hdr "Recorded"
note "artefact: ${OUT}"
note "$(jq -r '.reading.storage_mismatch' "${OUT}")"
echo ""
