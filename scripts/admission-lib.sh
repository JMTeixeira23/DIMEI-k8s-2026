#!/usr/bin/env bash
# scripts/admission-lib.sh
# Shared machinery for every suite in this repository that decides something by
# watching a pod be admitted or denied.
#
# Design rule: no result is ever written by hand. Every case records what it
# actually observed as a JSON document under ${RESULTS_DIR}. Workflow summaries,
# uploaded artefacts and the dissertation's result tables are all derived from
# those records. A case that does not run leaves no record and is reported as
# NOT_RUN — it cannot be silently reported as passing.
#
# This file holds only the machinery. A suite supplies its own manifest and
# sources this:
#
#     SCENARIOS=( "ID|title|requirements|DENY or ADMIT|expected policy/rule" ... )
#     KNOWN_RULES=( "policy/rule" ... )
#     RESULTS_DIR="${RESULTS_DIR:-/tmp/my-results}"
#     source "$(dirname "${BASH_SOURCE[0]}")/admission-lib.sh"
#
# Two suites use it: scripts/attack-lib.sh (attack simulations, Table 6.3) and
# scripts/testcase-lib.sh (pipeline admission tests, Table 6.2). They emit the
# same record schema on purpose, so one renderer serves both tables and the two
# suites cannot drift apart in how they define a pass.
#
# Sourced, not executed. Requires: bash 4+, jq, kubectl.

# shellcheck disable=SC2034  # several vars are consumed by the sourcing suite

if [ "${#SCENARIOS[@]}" -eq 0 ] 2>/dev/null || [ -z "${SCENARIOS+x}" ]; then
  echo "admission-lib: the sourcing suite must define a non-empty SCENARIOS array" >&2
  return 1 2>/dev/null || exit 1
fi
if [ -z "${KNOWN_RULES+x}" ]; then
  echo "admission-lib: the sourcing suite must define a KNOWN_RULES array" >&2
  return 1 2>/dev/null || exit 1
fi

# Exported so it reaches the summary script, which is invoked as a child
# process. Re-checked inside record_result rather than trusted here: a caller
# that writes `RESULTS_DIR=/x source scripts/attack-lib.sh` gets an assignment
# that does not outlive the source, and the records would then be written to /
# without complaint.
export RESULTS_DIR="${RESULTS_DIR:-/tmp/admission-results}"
mkdir -p "${RESULTS_DIR}"

# ── Manifest accessors ────────────────────────────────────────────────────────

# scenario_row <id> — echoes the manifest row, returns 1 if the id is unknown.
scenario_row() {
  local id="$1" row
  for row in "${SCENARIOS[@]}"; do
    if [ "${row%%|*}" = "${id}" ]; then
      printf '%s\n' "${row}"
      return 0
    fi
  done
  echo "admission-lib: unknown case id '${id}'" >&2
  return 1
}

# scenario_field <id> <1..5> — echoes one field of the manifest row.
scenario_field() {
  local id="$1" n="$2" row
  row="$(scenario_row "${id}")" || return 1
  printf '%s\n' "${row}" | cut -d'|' -f"${n}"
}

# ── Message handling ──────────────────────────────────────────────────────────

# flatten <text> — collapses multi-line kubectl output into one bounded line so
# it survives CSV and JSON transport intact.
flatten() {
  printf '%s' "$1" | tr '\n\r\t' '   ' | tr -s ' ' | sed 's/^ *//; s/ *$//' | cut -c1-1500
}

# detect_rules <message> — echoes the comma-separated policy/rule pairs named in
# a denial message, or an empty string when none are recognised.
detect_rules() {
  local msg="$1" pair policy rule found=""
  for pair in "${KNOWN_RULES[@]}"; do
    policy="${pair%%/*}"
    rule="${pair##*/}"
    case "${msg}" in
      *"${policy}"*)
        case "${msg}" in
          *"${rule}"*) found="${found:+${found},}${pair}" ;;
        esac
        ;;
    esac
  done
  printf '%s' "${found}"
}

# ── Admission probe ───────────────────────────────────────────────────────────
# probe <pod> <namespace> <image>
#
# Attempts to create a pod and classifies the result. Sets:
#   PROBE_OUTCOME  DENY | ADMIT | ERROR
#   PROBE_MESSAGE  flattened kubectl output
#   PROBE_PHASE    pod phase when admitted, empty otherwise
#
# ERROR is deliberately distinct from DENY: a failure to reach the API server or
# a malformed request is not evidence that a policy blocked anything. A suite
# that treats every non-zero exit as "the policy worked" will report a broken
# cluster as a security success.
probe() {
  local pod="$1" ns="$2" image="$3" out rc errexit=0

  kubectl delete pod "${pod}" -n "${ns}" --ignore-not-found >/dev/null 2>&1 || true
  kubectl wait "pod/${pod}" -n "${ns}" --for=delete --timeout=60s >/dev/null 2>&1 || true

  case $- in *e*) errexit=1 ;; esac
  set +e
  out=$(kubectl run "${pod}" \
    --image="${image}" \
    --restart=Never \
    --namespace="${ns}" \
    --command -- sh -c "echo ${pod}" 2>&1)
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

  # Exit status zero is not proof of admission — confirm the object exists.
  if kubectl get pod "${pod}" -n "${ns}" >/dev/null 2>&1; then
    PROBE_OUTCOME="ADMIT"
    PROBE_PHASE=$(kubectl get pod "${pod}" -n "${ns}" \
      -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
  else
    PROBE_OUTCOME="ERROR"
    PROBE_MESSAGE="kubectl run exited 0 but pod ${ns}/${pod} does not exist. ${PROBE_MESSAGE}"
  fi
}

# ── Result recording ──────────────────────────────────────────────────────────
# record_result <id> <observed> <image> <message> [detail]
#
# observed: DENY | ADMIT | ERROR | NOT_RUN
# Writes ${RESULTS_DIR}/<id>.json, prints a one-line verdict, and returns
# non-zero unless the observation matched the manifest's expectation. Callers
# run under `set -e`, so a case whose expectation is not met fails its step.
record_result() {
  local id="$1" observed="$2" image="$3" message="$4" detail="${5:-}"
  local title requirements expected expected_rule observed_rule outcome icon

  if [ -z "${RESULTS_DIR:-}" ] || [ ! -d "${RESULTS_DIR}" ]; then
    echo "admission-lib: RESULTS_DIR is unset or missing — refusing to write ${id}" >&2
    return 1
  fi

  title="$(scenario_field "${id}" 2)"        || return 1
  requirements="$(scenario_field "${id}" 3)" || return 1
  expected="$(scenario_field "${id}" 4)"     || return 1
  expected_rule="$(scenario_field "${id}" 5)" || return 1

  observed_rule="$(detect_rules "${message}")"

  case "${observed}" in
    ERROR|NOT_RUN) outcome="ERROR" ;;
    "${expected}") outcome="PASS"  ;;
    *)             outcome="FAIL"  ;;
  esac

  jq -n \
    --arg id            "${id}" \
    --arg title         "${title}" \
    --arg cloud         "${CLOUD:-unknown}" \
    --arg run_id        "${GITHUB_RUN_ID:-local}" \
    --arg requirements  "${requirements}" \
    --arg expected      "${expected}" \
    --arg observed      "${observed}" \
    --arg outcome       "${outcome}" \
    --arg expected_rule "${expected_rule}" \
    --arg observed_rule "${observed_rule}" \
    --arg image         "${image}" \
    --arg message       "$(flatten "${message}")" \
    --arg detail        "$(flatten "${detail}")" \
    --arg timestamp     "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{
      scenario:            $id,
      title:               $title,
      cloud:               $cloud,
      run_id:              $run_id,
      requirements:        ($requirements | split(",")),
      expected_admission:  $expected,
      observed_admission:  $observed,
      outcome:             $outcome,
      expected_rule:       $expected_rule,
      observed_rule:       $observed_rule,
      image:               $image,
      detail:              $detail,
      message:             $message,
      timestamp:           $timestamp
    }' > "${RESULTS_DIR}/${id}.json"

  case "${outcome}" in
    PASS)  icon="✅" ;;
    FAIL)  icon="❌" ;;
    *)     icon="⚠️" ;;
  esac

  echo "${icon} ${id} ${outcome} — expected ${expected}, observed ${observed}"
  if [ -n "${observed_rule}" ]; then
    echo "   blocked by: ${observed_rule}"
  fi
  if [ -n "${detail}" ]; then
    echo "   detail    : $(flatten "${detail}")"
  fi
  if [ -n "${message}" ]; then
    echo "   message   : $(flatten "${message}" | cut -c1-300)"
  fi

  [ "${outcome}" = "PASS" ]
}

# abort_scenario <id> <image> <reason>
# Records a case whose preconditions could not be established. Used when the
# setup itself failed, so the artefact distinguishes "the control did not hold"
# from "the test could not be staged".
abort_scenario() {
  local id="$1" image="$2" reason="$3"
  record_result "${id}" "ERROR" "${image}" "precondition not met: ${reason}" || true
  return 1
}

# ── Registry helpers ──────────────────────────────────────────────────────────

# push_and_digest <image:tag> — pushes and echoes the digest the registry now
# serves for that tag. Read back from the registry rather than from the local
# daemon: the registry's view is what Kyverno resolves at admission, and it is
# the only view that is correct after a tag has been moved.
push_and_digest() {
  local image="$1" digest=""

  docker push "${image}" >/dev/null

  digest=$(docker buildx imagetools inspect "${image}" \
    --format '{{.Manifest.Digest}}' 2>/dev/null || true)

  if [ -z "${digest}" ]; then
    digest=$(docker inspect --format='{{range .RepoDigests}}{{println .}}{{end}}' "${image}" 2>/dev/null \
      | grep "^${image%%:*}@" | head -1 | cut -d'@' -f2 || true)
  fi

  if [ -z "${digest}" ]; then
    echo "admission-lib: could not resolve a digest for ${image}" >&2
    return 1
  fi

  printf '%s\n' "${digest}"
}

# resolve_tag_digest <image:tag> — echoes the digest the tag currently points to.
resolve_tag_digest() {
  docker buildx imagetools inspect "$1" --format '{{.Manifest.Digest}}' 2>/dev/null || true
}
