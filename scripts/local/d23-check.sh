#!/usr/bin/env bash
# Offline check for the D23 fix. Not part of any workflow; run by hand.
#
# Exercises set-failure-policy.sh and webhook-state.sh against a fake kubectl so
# the three cases can be told apart without a cluster:
#
#   1. no ClusterPolicies, no resource webhooks  -> exit 3, names the real cause
#   2. resource webhooks already at the wanted   -> exit 0, no-op, no Helm
#   3. webhooks present but reporting the other  -> would upgrade (not exercised
#      here; it needs Helm)
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SHIM="$(mktemp -d)"
trap 'rm -rf "${SHIM}"' EXIT

make_kubectl() {  # <webhooks-json> <clusterpolicy-names>
  cat > "${SHIM}/kubectl" <<EOF
#!/usr/bin/env bash
case "\$*" in
  *validatingwebhookconfigurations*) cat <<'JSON'
$1
JSON
    ;;
  *clusterpolicies*) printf '%s' "$2" ;;
  *poddisruptionbudget*) echo "kyverno-admission-controller(minAvailable=2,allowed=1) " ;;
  *deployment*) echo 3 ;;
  *) echo "" ;;
esac
EOF
  chmod +x "${SHIM}/kubectl"
}

EMPTY='{"items":[]}'
IGNORE='{"items":[{"metadata":{"name":"kyverno-resource-validating-webhook-cfg"},"webhooks":[{"name":"validate.kyverno.svc-ignore","failurePolicy":"Ignore","timeoutSeconds":10,"rules":[{"resources":["pods"]}]},{"name":"kyverno-cleanup-controller.kyverno.svc","failurePolicy":"Ignore","timeoutSeconds":10,"rules":[{"resources":["*"]}]}]}]}'
FAIL='{"items":[{"metadata":{"name":"kyverno-resource-validating-webhook-cfg"},"webhooks":[{"name":"validate.kyverno.svc-fail","failurePolicy":"Fail","timeoutSeconds":10,"rules":[{"resources":["pods"]}]},{"name":"kyverno-cleanup-controller.kyverno.svc","failurePolicy":"Ignore","timeoutSeconds":10,"rules":[{"resources":["*"]}]}]}]}'

run_case() {  # <label> <webhooks> <policies> <mode> <expected-exit>
  local label="$1" hooks="$2" pols="$3" mode="$4" want="$5"
  make_kubectl "${hooks}" "${pols}"
  local out rc
  out=$(cd "${HERE}/.." && PATH="${SHIM}:${PATH}" RESULTS_DIR="${SHIM}/res" \
        SETTLE_SECONDS=0 bash scripts/set-failure-policy.sh "${mode}" 2>&1)
  rc=$?
  if [ "${rc}" = "${want}" ]; then
    echo "PASS  ${label} (exit ${rc})"
  else
    echo "FAIL  ${label}: expected exit ${want}, got ${rc}"
    printf '%s\n' "${out}" | sed 's/^/      /'
    return 1
  fi
  printf '%s\n' "${out}" | grep -E 'ERROR|no-op|already' | sed 's/^/      /' || true
}

FAILED=0
run_case "no policies, no webhooks -> exit 3" "${EMPTY}" "" fail 3 || FAILED=1
run_case "already Ignore -> no-op"            "${IGNORE}" "verify-image-signature" ignore 0 || FAILED=1
run_case "already Fail -> no-op"              "${FAIL}"   "verify-image-signature" fail 0 || FAILED=1

echo ""
echo "── webhook-state.sh classification ──"
for pair in "EMPTY:${EMPTY}:0" "IGNORE:${IGNORE}:3" "FAIL:${FAIL}:3"; do
  name="${pair%%:*}"; rest="${pair#*:}"; json="${rest%:*}"; count="${rest##*:}"
  make_kubectl "${json}" "$(head -c "${count}" /dev/zero | tr '\0' 'p' | sed 's/p/a /g')"
  PATH="${SHIM}:${PATH}" bash "${HERE}/webhook-state.sh" \
    | jq -c '{configuration, policy_webhooks, clusterpolicy_count}' \
    | sed "s/^/  ${name}: /"
done

echo ""
[ "${FAILED}" = "0" ] && echo "All D23 cases behaved as intended." || echo "SOME CASES FAILED"
exit "${FAILED}"
