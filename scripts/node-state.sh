#!/usr/bin/env bash
# scripts/node-state.sh
#
# Prints, as a JSON object on stdout, the worker hardware an evidence run
# executed on. Companion to webhook-state.sh, consumed by the same preflight
# steps and embedded in the same `environment` object, so every artefact
# describes its own machine as well as its own admission configuration.
#
# WHY THIS EXISTS
#
# Chapter 6 stated the Kubernetes version, the Kyverno version, the replica count
# and the admission configuration — and never once stated what the nodes were.
# Every latency figure in the evaluation therefore rested on hardware that no
# committed artefact identified, on either cloud. That is the one environment
# claim the revision could not derive from evidence (D38, changes.md §16a).
#
# It matters more than usual here because the two clouds are not identical: AWS
# runs `t3.medium` (2 vCPU, 4 GiB) and Azure runs `Standard_B2s_v2` (2 vCPU,
# 8 GiB). Both are burstable families, which is the property that makes the
# comparison fair, but "both are burstable" is a claim about the machines and
# belongs in an artefact rather than in prose.
#
#   instance_types    "t3.medium x2" — type and count, the headline fact
#   node_count        ready nodes, which is what the workload actually landed on
#   cpu_capacity      allocatable vCPU per distinct node shape
#   memory_capacity   allocatable memory per distinct node shape
#   kubelet_versions  skew between nodes is a confound if it ever appears
#   os_images         the node OS, for the same reason
#   zones             spread affects scheduling latency under concurrency
#
# Everything is reported per *distinct value*, not per node: two identical nodes
# collapse to one entry with a count, and a heterogeneous pool stays visible
# instead of being averaged into a number that describes neither node.
#
# No field is derived or interpreted — "burstable" is deliberately not computed
# here. The instance type is the fact; whether that family bursts is a statement
# about the cloud provider's catalogue and belongs in the text.
#
# Usage:  bash scripts/node-state.sh          # JSON to stdout
set -euo pipefail

ALL=$(kubectl get nodes -o json 2>/dev/null || echo '{"items":[]}')

# Everything below describes the *Ready* nodes only — the ones the workload could
# actually have landed on. A NotReady node contributes no capacity and including
# it would inflate the pool an artefact claims to have run on. Nothing is hidden:
# the ones left out are counted in `nodes_not_ready`.
NODES=$(printf '%s' "${ALL}" | jq '
  {items: [ .items[]? | select(.status.conditions[]?
      | select(.type == "Ready") | .status == "True") ]}' 2>/dev/null \
  || echo '{"items":[]}')

# Count nodes per instance type, e.g. "t3.medium x2". Both clouds populate the
# stable `node.kubernetes.io/instance-type` label; the older beta label is read
# as a fallback so this cannot silently report "unknown" on an older cluster.
TYPES=$(printf '%s' "${NODES}" | jq -r '
  [ .items[]?.metadata.labels
    | ."node.kubernetes.io/instance-type"
      // ."beta.kubernetes.io/instance-type" // "unknown" ]
  | group_by(.) | map("\(.[0]) x\(length)") | join(", ")' 2>/dev/null || true)

READY=$(printf '%s' "${NODES}" | jq -r '.items | length' 2>/dev/null || echo 0)

# Total minus Ready, rather than a second condition filter. The obvious spelling
# — selecting nodes whose Ready-condition list is empty — is wrong, because
# `select(.type=="Ready") | .status=="True"` yields the *value* false for a
# NotReady node, giving a one-element array and a silent count of zero.
NOT_READY=$(printf '%s' "${ALL}" | jq -r --argjson ready "${READY:-0}" '
  (.items | length) - $ready' 2>/dev/null || echo 0)

CPU=$(printf '%s' "${NODES}" | jq -r '
  [ .items[]?.status.allocatable.cpu ] | unique | join(",")' 2>/dev/null || true)

MEM=$(printf '%s' "${NODES}" | jq -r '
  [ .items[]?.status.allocatable.memory ] | unique | join(",")' 2>/dev/null || true)

KUBELET=$(printf '%s' "${NODES}" | jq -r '
  [ .items[]?.status.nodeInfo.kubeletVersion ] | unique | join(",")' 2>/dev/null || true)

OS=$(printf '%s' "${NODES}" | jq -r '
  [ .items[]?.status.nodeInfo.osImage ] | unique | join(" | ")' 2>/dev/null || true)

ZONES=$(printf '%s' "${NODES}" | jq -r '
  [ .items[]?.metadata.labels
    | ."topology.kubernetes.io/zone" // "unknown" ] | unique | join(",")' 2>/dev/null || true)

jq -n \
  --arg types "${TYPES:-unknown}" \
  --arg ready "${READY:-0}" \
  --arg notready "${NOT_READY:-0}" \
  --arg cpu "${CPU:-unknown}" \
  --arg mem "${MEM:-unknown}" \
  --arg kubelet "${KUBELET:-unknown}" \
  --arg os "${OS:-unknown}" \
  --arg zones "${ZONES:-unknown}" \
  '{instance_types: $types,
    node_count: ($ready | tonumber? // 0),
    nodes_not_ready: ($notready | tonumber? // 0),
    cpu_capacity: $cpu,
    memory_capacity: $mem,
    kubelet_versions: $kubelet,
    os_images: $os,
    zones: $zones}'
