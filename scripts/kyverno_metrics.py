#!/usr/bin/env python3
"""
Kyverno admission metrics — snapshot and delta.

Measures what the admission webhook actually costs, by reading Kyverno's own
histograms before and after a batch of pod creations and computing
`delta_sum / delta_count`. That ratio is the exact mean per-admission time over
the batch, with no dependence on bucket boundaries.

Deliberately does NOT use histogram_quantile: Kyverno's default buckets are far
coarser than the effect being measured, so quantiles interpolated from them are
meaningless at this scale. Per-request percentiles come from the pod-level
timings collected alongside, not from these histograms.

Why it scrapes every replica: the admission controller runs with 3 replicas and
each request is handled by exactly one of them, so a single pod's metrics cover
only part of the traffic. Each replica is read through the API server's pod
proxy subresource and the counters are summed, which is exact and needs no
port-forward. The same problem makes the API server's own
`apiserver_admission_webhook_admission_duration_seconds` unusable for deltas on
EKS — `kubectl get --raw /metrics` reaches one arbitrary instance of a
multi-instance control plane, so before and after may come from different
servers. It is collected only when asked for, and marked indicative.

Usage:
    python3 scripts/kyverno_metrics.py snapshot --out /tmp/before.json
    python3 scripts/kyverno_metrics.py snapshot --out /tmp/after.json
    python3 scripts/kyverno_metrics.py delta \\
        --before /tmp/before.json --after /tmp/after.json \\
        --condition enforce --out /tmp/delta-enforce.json \\
        --filter resource_namespace=supply-chain-demo

Filters are applied to the label set of each series; a series must match every
filter given. With no filters, all series are reported and the aggregate covers
all admission traffic in the window.
"""
import argparse
import json
import re
import subprocess
import sys
from datetime import datetime, timezone

# Histogram families read from Kyverno. Only _sum and _count are kept: buckets
# are recorded by Kyverno at a granularity that cannot resolve this effect.
FAMILIES = [
    "kyverno_admission_review_duration_seconds",
    "kyverno_policy_execution_duration_seconds",
]
COUNTERS = [
    "kyverno_admission_requests_total",
]

APISERVER_FAMILY = "apiserver_admission_webhook_admission_duration_seconds"

LABEL_RE = re.compile(r'([a-zA-Z_][a-zA-Z0-9_]*)="((?:[^"\\]|\\.)*)"')


def kubectl(args, check=True):
    proc = subprocess.run(["kubectl", *args], capture_output=True, text=True)
    if check and proc.returncode != 0:
        sys.exit(f"kubectl {' '.join(args)} failed:\n{proc.stderr.strip()}")
    return proc.stdout


def admission_pods(namespace, selector):
    out = kubectl([
        "get", "pods", "-n", namespace, "-l", selector,
        "--field-selector=status.phase=Running",
        "-o", "jsonpath={range .items[*]}{.metadata.name}{'\\n'}{end}",
    ])
    pods = [p.strip() for p in out.splitlines() if p.strip()]
    if not pods:
        sys.exit(f"no running pods matching {selector} in namespace {namespace}")
    return pods


def scrape_pod(namespace, pod, port):
    return kubectl([
        "get", "--raw",
        f"/api/v1/namespaces/{namespace}/pods/{pod}:{port}/proxy/metrics",
    ])


def parse_labels(blob):
    return {m.group(1): m.group(2) for m in LABEL_RE.finditer(blob)} if blob else {}


def parse_prometheus(text, names):
    """Return {(series_name, frozen_labels): float} for the requested families.

    Matches `name`, `name_sum`, `name_count` — bucket series are skipped.
    """
    wanted = set()
    for n in names:
        wanted.update({n, f"{n}_sum", f"{n}_count"})

    series = {}
    for line in text.splitlines():
        if not line or line.startswith("#"):
            continue
        brace = line.find("{")
        if brace == -1:
            parts = line.split()
            if len(parts) < 2:
                continue
            name, labels_blob, value = parts[0], "", parts[-1]
        else:
            name = line[:brace]
            close = line.rfind("}")
            labels_blob = line[brace + 1:close]
            value = line[close + 1:].strip().split()[0]

        if name not in wanted:
            continue
        try:
            val = float(value)
        except ValueError:
            continue

        labels = parse_labels(labels_blob)
        key = (name, tuple(sorted(labels.items())))
        series[key] = series.get(key, 0.0) + val
    return series


def cmd_snapshot(args):
    pods = admission_pods(args.namespace, args.selector)

    totals = {}
    for pod in pods:
        text = scrape_pod(args.namespace, pod, args.port)
        for key, val in parse_prometheus(text, FAMILIES + COUNTERS).items():
            totals[key] = totals.get(key, 0.0) + val

    snapshot = {
        "taken_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "namespace": args.namespace,
        "replicas_scraped": pods,
        "series": [
            {"name": name, "labels": dict(labels), "value": value}
            for (name, labels), value in sorted(totals.items())
        ],
    }

    if args.apiserver:
        text = kubectl(["get", "--raw", "/metrics"], check=False)
        api = parse_prometheus(text, [APISERVER_FAMILY])
        snapshot["apiserver"] = {
            "indicative_only": True,
            "caveat": "read from one arbitrary API server instance; on a "
                      "multi-instance managed control plane consecutive reads "
                      "may hit different servers, so deltas are not reliable",
            "series": [
                {"name": name, "labels": dict(labels), "value": value}
                for (name, labels), value in sorted(api.items())
            ],
        }

    with open(args.out, "w") as fh:
        json.dump(snapshot, fh, indent=2)
    print(f"snapshot: {len(snapshot['series'])} series from "
          f"{len(pods)} replica(s) -> {args.out}")


def index(snapshot):
    return {
        (s["name"], tuple(sorted(s["labels"].items()))): s["value"]
        for s in snapshot["series"]
    }


def matches(labels, filters):
    return all(labels.get(k) == v for k, v in filters.items())


def cmd_delta(args):
    with open(args.before) as fh:
        before = json.load(fh)
    with open(args.after) as fh:
        after = json.load(fh)

    if before["replicas_scraped"] != after["replicas_scraped"]:
        print("WARNING: the set of admission-controller replicas changed between "
              "snapshots. A restarted pod resets its counters, so this delta may "
              "understate the true totals.", file=sys.stderr)

    filters = dict(f.split("=", 1) for f in args.filter)
    b, a = index(before), index(after)

    families = {}
    for family in FAMILIES:
        rows = []
        total_sum = total_count = 0.0
        seen = matched = 0
        for key in {k for k in set(a) | set(b) if k[0] == f"{family}_count"}:
            labels = dict(key[1])
            seen += 1
            if not matches(labels, filters):
                continue
            matched += 1
            d_count = a.get(key, 0.0) - b.get(key, 0.0)
            sum_key = (f"{family}_sum", key[1])
            d_sum = a.get(sum_key, 0.0) - b.get(sum_key, 0.0)
            if d_count <= 0:
                continue
            rows.append({
                "labels": labels,
                "delta_count": d_count,
                "delta_sum_seconds": d_sum,
                "mean_ms": (d_sum / d_count) * 1000.0,
            })
            total_sum += d_sum
            total_count += d_count

        rows.sort(key=lambda r: -r["delta_count"])
        families[family] = {
            "series": rows,
            "series_in_family": seen,
            "series_matching_filters": matched,
            "aggregate": {
                "delta_count": total_count,
                "delta_sum_seconds": total_sum,
                "mean_ms": (total_sum / total_count) * 1000.0 if total_count else None,
            },
        }

    counters = {}
    for counter in COUNTERS:
        total = 0.0
        for key in {k for k in set(a) | set(b) if k[0] == counter}:
            if matches(dict(key[1]), filters):
                total += a.get(key, 0.0) - b.get(key, 0.0)
        counters[counter] = total

    result = {
        "condition": args.condition,
        "filters": filters,
        "window": {"from": before["taken_at"], "to": after["taken_at"]},
        "replicas_scraped": after["replicas_scraped"],
        "method": "delta_sum / delta_count over the measurement window; "
                  "histogram buckets deliberately unused",
        "histograms": families,
        "counters": counters,
    }

    with open(args.out, "w") as fh:
        json.dump(result, fh, indent=2)

    print(f"\n=== {args.condition} "
          f"({', '.join(f'{k}={v}' for k, v in filters.items()) or 'no filter'}) ===")
    for family, data in families.items():
        agg = data["aggregate"]
        if not agg["delta_count"]:
            if filters and not data["series_matching_filters"]:
                print(f"  {family}: none of its {data['series_in_family']} series "
                      f"carry these labels — this family is not labelled by the "
                      f"filtered dimension; use the unfiltered delta for it")
            else:
                print(f"  {family}: no admissions in the window")
            continue
        print(f"  {family}: n={agg['delta_count']:.0f}  "
              f"mean={agg['mean_ms']:.2f} ms")
        for row in data["series"][:args.top]:
            label_str = ", ".join(f"{k}={v}" for k, v in sorted(row["labels"].items()))
            print(f"      n={row['delta_count']:>5.0f}  "
                  f"mean={row['mean_ms']:>8.2f} ms   {label_str}")
    for counter, value in counters.items():
        print(f"  {counter}: +{value:.0f}")
    print(f"  written to {args.out}")


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="command", required=True)

    snap = sub.add_parser("snapshot", help="scrape every admission replica")
    snap.add_argument("--out", required=True)
    snap.add_argument("--namespace", default="kyverno")
    snap.add_argument("--selector",
                      default="app.kubernetes.io/component=admission-controller")
    snap.add_argument("--port", default="8000")
    snap.add_argument("--apiserver", action="store_true",
                      help="also record API server webhook metrics (indicative only)")
    snap.set_defaults(func=cmd_snapshot)

    delta = sub.add_parser("delta", help="difference two snapshots")
    delta.add_argument("--before", required=True)
    delta.add_argument("--after", required=True)
    delta.add_argument("--out", required=True)
    delta.add_argument("--condition", default="unnamed")
    delta.add_argument("--filter", action="append", default=[],
                       metavar="LABEL=VALUE")
    delta.add_argument("--top", type=int, default=8,
                       help="how many per-series rows to print")
    delta.set_defaults(func=cmd_delta)

    args = ap.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
