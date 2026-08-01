#!/usr/bin/env bash
# scripts/probe-lib.sh
#
# What a latency probe *is*, in one place. Sourced by measure-admission.sh (the
# sequential experiments) and measure-concurrency.sh (the parallel sweep).
#
# Extracted rather than copied. Both experiments depend on the probe having
# exactly two properties, and a second definition that drifted from this one
# would invalidate the comparison between them without anything failing:
#
#   1. It is created in the namespace the policies match. The original version of
#      the latency experiment created probes in `default`, which no policy
#      matches, so nothing measured was ever evaluated.
#   2. It is unschedulable — the nodeSelector matches no node in either cluster.
#      Admission runs in full, because admission happens at create time, before
#      scheduling; image pull, scheduling and container execution are excluded.
#      The original version timed pod completion, which buried a ~45 ms effect
#      under ~32 seconds of pull and schedule.
#
# Every function here takes the condition and image explicitly rather than
# reading globals, so the parallel sweep can call it from a subshell.

PROBE_LABEL="${PROBE_LABEL:-admission-latency}"

probe_manifest() {  # <pod-name> <condition> <image> [namespace]
  local name="$1" condition="$2" image="$3" ns="${4:-${NAMESPACE:-supply-chain-demo}}"
  cat <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: ${name}
  namespace: ${ns}
  labels:
    experiment: ${PROBE_LABEL}
    condition: ${condition}
spec:
  restartPolicy: Never
  nodeSelector:
    kyverno-admission-latency-probe: "never-schedules"
  containers:
    - name: probe
      image: ${image}
      command: ["sh", "-c", "exit 0"]
YAML
}

# Echoes "true" when the API server accepted the create, "false" otherwise.
#
# A non-zero exit from `kubectl create` is recorded as a rejection, not as an
# error: for these experiments the policies admit every probe, so a rejection is
# itself the signal that something is wrong with the run, and it is counted and
# reported rather than swallowed.
create_probe() {  # <pod-name> <condition> <image> [namespace]
  if probe_manifest "$@" | kubectl create -f - >/dev/null 2>&1; then
    echo "true"
  else
    echo "false"
  fi
}

# Deletes this experiment's probes. Always call it *after* the closing metric
# snapshot, so deletions never land inside a measured window.
probe_cleanup() {  # [namespace]
  local ns="${1:-${NAMESPACE:-supply-chain-demo}}"
  kubectl delete pods -n "${ns}" \
    -l "experiment=${PROBE_LABEL}" --wait=false >/dev/null 2>&1 || true
}
