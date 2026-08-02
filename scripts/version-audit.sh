#!/usr/bin/env bash
# scripts/version-audit.sh
# Every third-party version this repository pins, next to the version currently
# published, and what it would cost to change it.
#
# This exists because "is anything out of date?" was being answered by reading
# files and remembering release numbers. It is answered here by asking the
# upstreams, so the answer is derived rather than recalled — the same rule the
# evidence artefacts follow.
#
# The important column is the last one. Some of these tools are *part of the
# system under test*: Kyverno enforces the policies, Cosign produces the
# signatures and Syft the SBOMs that Kyverno then verifies. Changing any of them
# changes what was measured, and every number in Chapter 6 with it. Others are
# scaffolding and can be bumped freely.
#
# Usage:
#   bash scripts/version-audit.sh              # table
#   bash scripts/version-audit.sh --json       # machine-readable, for an artefact
#
# Requires network access. Without it, the pinned column is still correct and
# the latest column reads "unknown".

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${HERE}"

JSON=0
[ "${1:-}" = "--json" ] && JSON=1

# ── Read what the repository actually pins, from the files ───────────────────
# Never hardcoded here: if a pin moves and this script is not updated, it must
# report the new value, not the value someone typed into this script.

pin_kyverno_aws=$(grep -oP 'KYVERNO_VERSION="\K[^"]+' bootstrap-aws.sh 2>/dev/null | head -1)
pin_kyverno_azure=$(grep -oP 'KYVERNO_VERSION="\K[^"]+' bootstrap-azure.sh 2>/dev/null | head -1)
pin_kyverno_failpol=$(grep -oP 'KYVERNO_VERSION="\$\{KYVERNO_VERSION:-\K[^}]+' scripts/set-failure-policy.sh 2>/dev/null | head -1)
pin_cosign=$(grep -ohP 'cosign/releases/download/\Kv[0-9.]+' .github/workflows/*.yml 2>/dev/null | sort -u | paste -sd, -)
pin_cosign_action=$(grep -ohP 'cosign-release: \K\S+' .github/workflows/*.yml 2>/dev/null | sort -u | paste -sd, -)
pin_syft=$(grep -ohP "sh -s -- -b \S+ \Kv[0-9.]+" .github/workflows/*.yml 2>/dev/null | sort -u | paste -sd, -)
pin_crane=$(grep -ohP 'go-containerregistry/releases/download/\Kv[0-9.]+' .github/workflows/*.yml 2>/dev/null | sort -u | paste -sd, -)

# ── Ask the upstreams ────────────────────────────────────────────────────────

gh_latest() {  # gh_latest <owner/repo>
  curl -fsS --max-time 15 "https://api.github.com/repos/$1/releases/latest" 2>/dev/null \
    | grep -oP '"tag_name":\s*"\K[^"]+' | head -1
}

helm_latest_kyverno() {
  # The chart index is the authority for chart-version → app-version.
  curl -fsS --max-time 20 https://kyverno.github.io/kyverno/index.yaml 2>/dev/null \
    | awk '
        /^  kyverno:/      { in_kyverno = 1; next }
        /^  [a-z-]+:/      { in_kyverno = 0 }
        in_kyverno && /appVersion:/ && !app { gsub(/[ \t]/,"",$2); app = $2 }
        in_kyverno && /^    version:/ && !chart { gsub(/[ \t]/,"",$2); chart = $2 }
        END { if (chart) printf "%s (app %s)\n", chart, app }'
}

lat_kyverno=$(helm_latest_kyverno)
lat_cosign=$(gh_latest sigstore/cosign)
lat_syft=$(gh_latest anchore/syft)
lat_crane=$(gh_latest google/go-containerregistry)

# ── Report ───────────────────────────────────────────────────────────────────

row() {  # row <tool> <pinned> <latest> <class> <note>
  if [ "${JSON}" = "1" ]; then
    printf '%s\n' "$(jq -n --arg t "$1" --arg p "$2" --arg l "$3" --arg c "$4" --arg n "$5" \
      '{tool:$t, pinned:$p, latest:$l, class:$c, note:$n}')"
  else
    printf '  %-22s %-18s %-24s %-14s %s\n' "$1" "${2:-?}" "${3:-unknown}" "$4" "$5"
  fi
}

if [ "${JSON}" = "0" ]; then
  echo "════════════════════════════════════════════════════════════════════════"
  echo "  Third-party versions — pinned in this repository vs published upstream"
  echo "  $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "════════════════════════════════════════════════════════════════════════"
  printf '  %-22s %-18s %-24s %-14s %s\n' TOOL PINNED LATEST CLASS "CHANGING IT"
  printf '  %-22s %-18s %-24s %-14s %s\n' ---- ------ ------ ----- -----------
fi

row "Kyverno chart (AWS)"   "${pin_kyverno_aws}"     "${lat_kyverno}"  "UNDER TEST" \
    "invalidates every result in Ch. 6"
row "Kyverno chart (Azure)" "${pin_kyverno_azure}"   "${lat_kyverno}"  "UNDER TEST" \
    "must equal AWS or the clouds are incomparable"
row "Kyverno (failure-pol)" "${pin_kyverno_failpol}" "${lat_kyverno}"  "UNDER TEST" \
    "must equal the bootstrap pin"
row "Cosign (workflows)"    "${pin_cosign}"          "${lat_cosign}"   "UNDER TEST" \
    "produces the signatures Kyverno verifies"
row "Cosign (installer)"    "${pin_cosign_action}"   "${lat_cosign}"   "UNDER TEST" \
    "same binary, pipeline path"
row "Syft"                  "${pin_syft}"            "${lat_syft}"     "UNDER TEST" \
    "produces the SBOMs Kyverno verifies"
row "crane"                 "${pin_crane}"           "${lat_crane}"    "scaffolding" \
    "stages E3 only; nothing verifies it"

if [ "${JSON}" = "0" ]; then
  cat <<'NOTE'

  ── How to read this ──────────────────────────────────────────────────────
  UNDER TEST  the tool is part of the system being evaluated. Its version is a
              property of the result, not an implementation detail. Changing it
              before the experiment freeze means re-running everything that
              depends on it — on both clouds.
  scaffolding harness only. Bump freely.

  The Kyverno pin is the one that matters. Both bootstraps and
  scripts/set-failure-policy.sh must agree, or a cluster can be rebuilt onto a
  different version than the one it was measured on, silently.

  Every evidence artefact records the Kyverno image it ran against
  (run.kyverno_image), so any artefact can be checked against this table.
NOTE
fi
