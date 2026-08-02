#!/usr/bin/env bash
# scripts/evasion-lib.sh
# The evasion suite for .github/workflows/evasion-tests.yml — revision item 2.2.
#
# The attack suite (scripts/attack-lib.sh) asks whether the three policies block
# the attacks they were designed to block. This suite asks the opposite and more
# interesting question: **where does the enforcement boundary actually fall, and
# what walks through it.**
#
# Two of the four cases are PREDICTED TO SUCCEED AS ATTACKS. A row that matches
# its prediction here is therefore not a green tick. Every record carries a
# `control` field saying what a matched prediction means:
#
#   control = holds   the prediction is that the control denies the attempt
#   control = evaded  the prediction is that the attempt gets through
#
# Read that field before quoting any number from this suite. "4/4 as predicted"
# means the boundary is where this document says it is — not that four attacks
# were blocked. The dissertation table renderer (scripts/attack_table.py
# --preset evasion) prints the column for exactly this reason.
#
# The record schema, the definition of a pass and the probe machinery are shared
# with the attack suite through scripts/admission-lib.sh, so the two suites
# cannot drift apart in what they call an admission.
#
# Sourced, not executed:  source scripts/evasion-lib.sh
#
# Requires: bash 4+, jq, kubectl, docker, cosign, crane.

# shellcheck disable=SC2034  # several vars are consumed by the caller

# ── Which cases this run claims to cover ─────────────────────────────────────
#
# The manifest depends on the ref the run was dispatched from, and that is not a
# convenience — it is a correctness constraint.
#
# Every keyless signature minted inside a workflow run carries that run's ref in
# its certificate SAN. The signature policy pins `...workflows/*@refs/heads/main`.
# So a run dispatched from a branch cannot mint a signature that satisfies the
# policy, and E1–E3 — all of which need a *compliant baseline artefact* before
# they can isolate the thing they are testing — would fail their preconditions
# for a reason that has nothing to do with what they are testing. Off main the
# only meaningful case is E4, whose whole subject is that ref.
#
# Consequently: dispatch on main for E1–E3, dispatch on a branch for E4. The
# artefact records which set it covered, so a reader can see that the suite did
# not quietly skip anything.
#
# Fields: id | title | requirements | predicted outcome | expected rule | control

EVASION_REF="${EVASION_REF:-${GITHUB_REF_NAME:-main}}"

if [ "${EVASION_REF}" = "main" ]; then
  SCENARIOS=(
    "E1|Signature and attestations minted by a different workflow of the same repository on main|SR-01|ADMIT|none — the pinned identity's workflow path is a wildcard|evaded"
    "E2|Tag moved to unsigned content after the pod was admitted (post-admission TOCTOU)|SR-02|EVADED|none — no admission review occurs when the kubelet re-pulls|evaded"
    "E3|Valid attestations replayed onto a different, correctly signed digest|SR-03,SR-04|DENY|verify-sbom-cyclonedx/check-sbom-cyclonedx|holds"
  )
else
  SCENARIOS=(
    "E4|Signature and attestations minted on a ref other than refs/heads/main|SR-01|DENY|verify-image-signature/check-image-signature|holds"
  )
fi

KNOWN_RULES=(
  "verify-image-signature/block-unapproved-registry"
  "verify-image-signature/check-image-signature"
  "verify-sbom-cyclonedx/check-sbom-cyclonedx"
  "verify-slsa-provenance/check-slsa-provenance"
)

RESULTS_DIR="${RESULTS_DIR:-/tmp/evasion-results}"

# shellcheck source=scripts/admission-lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/admission-lib.sh"

# ── Recording ─────────────────────────────────────────────────────────────────

# record_evasion <id> <observed> <image> <message> [detail] [evidence-json]
#
# record_result decides pass/fail by comparing the observation against the
# manifest's prediction; this adds the two things the shared record has no
# concept of:
#
#   control    static: what a matched prediction means for the control
#   evidence   whatever the case measured that is not an admission outcome
#
# E2's verdict is not an admission outcome at all — the pod is admitted, and the
# question is what runs inside it afterwards — so its evidence block is the
# result, and the summary line only tells you whether that matched what was
# predicted.
record_evasion() {
  local id="$1" observed="$2" image="$3" message="$4"
  local detail="${5:-}" evidence="${6:-null}" control rc=0 file

  control="$(scenario_field "${id}" 6)" || return 1

  record_result "${id}" "${observed}" "${image}" "${message}" "${detail}" || rc=$?

  file="${RESULTS_DIR}/${id}.json"
  if [ -f "${file}" ]; then
    if jq --arg control "${control}" --argjson evidence "${evidence}" \
         '. + {control: $control, evidence: $evidence}' \
         "${file}" > "${file}.tmp" 2>/dev/null; then
      mv "${file}.tmp" "${file}"
    else
      rm -f "${file}.tmp"
      echo "evasion-lib: could not attach control/evidence to ${id} — the" >&2
      echo "             evidence block was not valid JSON. Record kept as-is." >&2
      rc=1
    fi
  fi

  case "${control}" in
    holds)  echo "   control   : holds — matching this prediction means the control blocked the attempt" ;;
    evaded) echo "   control   : EVADED — matching this prediction means the attempt got through" ;;
    *)      echo "   control   : ${control}" ;;
  esac
  return "${rc}"
}

# ── E2's probe ────────────────────────────────────────────────────────────────

# probe_pull_always <pod> <namespace> <image>
#
# admission-lib's probe() creates a `--restart=Never` pod that runs once. E2
# needs the opposite: a pod that stays in the cluster and asks the registry for
# its image on every container start, which is the only way the kubelet can
# observe a tag that moved after admission.
#
# Sets the same PROBE_OUTCOME / PROBE_MESSAGE / PROBE_PHASE contract as probe(),
# so the classification of admitted-versus-denied is identical in both suites.
#
# imagePullPolicy: Always is not a trick to make the attack work — it is the
# setting Kubernetes documents for mutable tags, and the one a reader following
# the usual advice would already have. restartPolicy: Always plus a container
# that exits gives the kubelet a reason to start the container again, which is
# when the re-pull happens.
probe_pull_always() {
  local pod="$1" ns="$2" image="$3" out rc errexit=0

  kubectl delete pod "${pod}" -n "${ns}" --ignore-not-found >/dev/null 2>&1 || true
  kubectl wait "pod/${pod}" -n "${ns}" --for=delete --timeout=60s >/dev/null 2>&1 || true

  case $- in *e*) errexit=1 ;; esac
  set +e
  out=$(kubectl apply -n "${ns}" -f - 2>&1 <<MANIFEST
apiVersion: v1
kind: Pod
metadata:
  name: ${pod}
  labels:
    suite: evasion
spec:
  restartPolicy: Always
  containers:
    - name: app
      image: ${image}
      imagePullPolicy: Always
MANIFEST
)
  rc=$?
  if [ "${errexit}" = "1" ]; then set -e; fi

  PROBE_MESSAGE="$(flatten "${out}")"
  PROBE_PHASE=""

  if [ "${rc}" -ne 0 ]; then
    if printf '%s' "${out}" | grep -qiE 'denied the request|blocked due to the following polic'; then
      PROBE_OUTCOME="DENY"
    else
      PROBE_OUTCOME="ERROR"
    fi
    return 0
  fi

  if kubectl get pod "${pod}" -n "${ns}" >/dev/null 2>&1; then
    PROBE_OUTCOME="ADMIT"
    PROBE_PHASE=$(kubectl get pod "${pod}" -n "${ns}" \
      -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
  else
    PROBE_OUTCOME="ERROR"
    PROBE_MESSAGE="kubectl apply exited 0 but pod ${ns}/${pod} does not exist. ${PROBE_MESSAGE}"
  fi
}

# pod_field <pod> <namespace> <jsonpath> — echoes one field, empty on failure.
pod_field() {
  kubectl get pod "$1" -n "$2" -o jsonpath="$3" 2>/dev/null || true
}

# await_image_id <pod> <ns> <timeout-seconds>
#
# Waits until the container has started at least once and the kubelet has
# resolved its image, leaving the id in AWAIT_IMAGE_ID. Returns 1 on timeout.
#
# Deliberately not `kubectl wait --for=condition=Ready`: E2's container exits
# every few seconds so that the kubelet has a reason to start it again, which
# means Ready flaps and a wait on it is a coin toss. A resolved imageID is both
# stabler and closer to the question — it is the digest that actually got run.
await_image_id() {
  local pod="$1" ns="$2" timeout="$3" now start
  start=${SECONDS}
  AWAIT_IMAGE_ID=""
  while [ $((SECONDS - start)) -lt "${timeout}" ]; do
    now="$(pod_field "${pod}" "${ns}" '{.status.containerStatuses[0].imageID}')"
    if [ -n "${now}" ]; then
      AWAIT_IMAGE_ID="${now}"
      return 0
    fi
    sleep 5
  done
  return 1
}

# await_image_change <pod> <ns> <image-id-before> <timeout-seconds>
#
# Polls the container's resolved imageID until it differs from the one recorded
# at admission. Returns 0 on change, 1 on timeout, and sets:
#
#   AWAIT_IMAGE_ID  the id observed at the end, changed or not
#   AWAIT_SECONDS   how long it took — the residual TOCTOU window §5.4 of the
#                   dissertation currently promises to measure
#
# Sets globals rather than echoing them because a command substitution would run
# it in a subshell and the timing would be lost with it.
await_image_change() {
  local pod="$1" ns="$2" before="$3" timeout="$4" now="" start
  start=${SECONDS}
  AWAIT_IMAGE_ID=""
  AWAIT_SECONDS=0
  while [ $((SECONDS - start)) -lt "${timeout}" ]; do
    now="$(pod_field "${pod}" "${ns}" '{.status.containerStatuses[0].imageID}')"
    if [ -n "${now}" ] && [ "${now}" != "${before}" ]; then
      AWAIT_IMAGE_ID="${now}"
      AWAIT_SECONDS=$((SECONDS - start))
      return 0
    fi
    sleep 5
  done
  AWAIT_IMAGE_ID="${now}"
  AWAIT_SECONDS=$((SECONDS - start))
  return 1
}

# ── Attestation helpers ───────────────────────────────────────────────────────

# attestation_tag <digest> — the OCI tag cosign stores attestations under for a
# given digest: sha256:abc… becomes sha256-abc….att
attestation_tag() {
  printf '%s.att\n' "${1/:/-}"
}
