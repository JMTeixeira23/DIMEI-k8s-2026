#!/usr/bin/env python3
"""
Build the admission-latency evidence artefact from one measurement run.

Reads what scripts/measure-admission.sh produced and reports two things that
answer different questions. Keeping them apart is the point of this script.

  in-webhook cost   Kyverno's own histograms, delta_sum/delta_count summed over
                    every admission replica. Exact, free of client and network
                    cost. Exists only where a webhook actually ran: in the
                    baseline condition the policies are deleted, Kyverno
                    deregisters its resource webhook, and no admission review
                    happens at all. There is therefore no baseline value for
                    this metric, by construction rather than by omission.

  request cost      Client-side wall clock around each create request. Includes
                    kubectl process startup and the runner-to-API-server round
                    trip, which are constant across conditions, so differences
                    between conditions are attributable but absolute values are
                    not admission latency. This is the only per-request sample,
                    so all distributions and percentiles come from it — and it
                    is the only view in which baseline can be compared at all.

Percentiles use the nearest-rank method on the sorted samples: no interpolation,
no distributional assumption, and every reported value is an observation that
actually occurred.

Usage:
    python3 scripts/latency_report.py --results-dir /tmp/latency-results \\
        --cloud aws --out latency-aws.json --csv latency-aws.csv
"""
import argparse
import csv
import glob
import json
import os
import statistics
import sys

KYVERNO_FAMILY = "kyverno_admission_review_duration_seconds"
POLICY_FAMILY = "kyverno_policy_execution_duration_seconds"


def percentile(sorted_values, fraction):
    """Nearest-rank percentile: the smallest observed value at or above rank."""
    if not sorted_values:
        return None
    rank = max(1, min(len(sorted_values),
                      int(-(-fraction * len(sorted_values) // 1))))
    return sorted_values[rank - 1]


def summarise(samples):
    if not samples:
        return None
    ordered = sorted(samples)
    return {
        "n": len(ordered),
        "min_ms": ordered[0],
        "p50_ms": percentile(ordered, 0.50),
        "p95_ms": percentile(ordered, 0.95),
        "p99_ms": percentile(ordered, 0.99),
        "max_ms": ordered[-1],
        "mean_ms": round(statistics.mean(ordered), 2),
        "stdev_ms": round(statistics.stdev(ordered), 2) if len(ordered) > 1 else 0.0,
    }


def read_requests(path):
    """condition -> accepted [client_ms], plus rejected counts and totals.

    A condition where every request was rejected is still a condition: it means
    the probe image was not admissible, which is a result and not an absence of
    data. Conditions are keyed off every row seen, not only accepted ones.
    """
    accepted, rejected, seen = {}, {}, {}
    if not os.path.exists(path):
        return accepted, rejected, seen
    with open(path) as fh:
        for row in csv.DictReader(fh):
            cond = row["condition"]
            seen[cond] = seen.get(cond, 0) + 1
            accepted.setdefault(cond, [])
            rejected.setdefault(cond, 0)
            if row.get("accepted") == "true":
                accepted[cond].append(int(row["client_ms"]))
            else:
                rejected[cond] += 1
    return accepted, rejected, seen


def read_delta(results_dir, condition):
    path = os.path.join(results_dir, f"{condition}-delta.json")
    if not os.path.exists(path):
        return None
    with open(path) as fh:
        return json.load(fh)


def webhook_cost(delta, requests_sent):
    """In-webhook cost for one condition.

    Kyverno counts one admission review per webhook invocation, and a single pod
    creation passes through both the mutating and the validating webhook. The
    review count is therefore a multiple of the number of requests, and the mean
    below is per *review*, not per pod. `per_request_ms` is the figure to compare
    against client-side request cost, and the one Chapter 6 should quote as the
    admission cost of creating a pod.
    """
    if not delta:
        return None
    agg = delta["histograms"].get(KYVERNO_FAMILY, {}).get("aggregate", {})
    if not agg.get("delta_count"):
        return None
    reviews = agg["delta_count"]
    total_ms = agg["delta_sum_seconds"] * 1000.0
    return {
        "admission_reviews": reviews,
        "reviews_per_request": round(reviews / requests_sent, 2) if requests_sent else None,
        "mean_per_review_ms": round(agg["mean_ms"], 3),
        "per_request_ms": round(total_ms / requests_sent, 3) if requests_sent else None,
        "total_seconds": round(agg["delta_sum_seconds"], 4),
    }


def policy_breakdown(results_dir, condition):
    """Per-policy execution cost, from the unfiltered delta.

    The policy-execution family is labelled by policy and rule, not by
    namespace, so the namespace-filtered delta cannot carry it.
    """
    path = os.path.join(results_dir, f"{condition}-delta-unfiltered.json")
    if not os.path.exists(path):
        return []
    with open(path) as fh:
        data = json.load(fh)
    rows = data["histograms"].get(POLICY_FAMILY, {}).get("series", [])
    # The full label set is kept: the same policy and rule appear as several
    # series distinguished by labels other than the name, and dropping those
    # labels makes the breakdown look like duplicated rows.
    return [
        {
            "policy": r["labels"].get("policy_name", "?"),
            "rule": r["labels"].get("rule_name", "?"),
            "executions": r["delta_count"],
            "mean_ms": round(r["mean_ms"], 3),
            "total_ms": round(r["delta_sum_seconds"] * 1000.0, 3),
            "labels": r["labels"],
        }
        for r in rows
    ]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--results-dir", required=True)
    ap.add_argument("--cloud", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--csv", required=True)
    args = ap.parse_args()

    env_path = os.path.join(args.results_dir, "_environment.json")
    environment = {}
    if os.path.exists(env_path):
        with open(env_path) as fh:
            environment = json.load(fh)

    # The execution order and its seed, when the matrix runner recorded them.
    # Carried into the artefact so a run can be repeated exactly and so the
    # order can be cited when discussing per-condition tails.
    order_path = os.path.join(args.results_dir, "_order.json")
    if os.path.exists(order_path):
        with open(order_path) as fh:
            environment["execution"] = json.load(fh)

    requests, rejected, sent = read_requests(
        os.path.join(args.results_dir, "requests.csv"))

    # Conditions are reported in a canonical reading order, not the order they
    # were measured: measurement order is randomised on purpose, and a table
    # whose rows move between runs is hard to compare. The order actually
    # executed is preserved in environment["execution"]. Conditions are still
    # discovered from what exists, so one that was skipped is absent rather than
    # reported as zero, and anything unrecognised keeps its measured position.
    known_order = ["baseline", "audit", "enforce", "enforce-nocache",
                   "size-small", "size-medium", "size-large", "size-xlarge"]
    # Concurrency levels sort numerically because the condition name is
    # zero-padded (conc-001 … conc-050); appending them here keeps the sweep in
    # ascending order in the report regardless of the order measured.
    known_order += sorted(c for c in sent if c.startswith("conc-"))
    measured = [c for c in known_order if c in sent]
    measured += [c for c in sent if c not in known_order]

    conditions = []
    for cond in measured:
        delta = read_delta(args.results_dir, cond)
        conditions.append({
            "condition": cond,
            "requests_sent": sent.get(cond, 0),
            "request_cost": summarise(requests.get(cond, [])),
            "rejected_requests": rejected.get(cond, 0),
            "in_webhook_cost": webhook_cost(delta, sent.get(cond, 0)),
            "policy_breakdown": policy_breakdown(args.results_dir, cond),
        })

    by_name = {c["condition"]: c for c in conditions}

    def request_delta(a, b):
        ca, cb = by_name.get(a), by_name.get(b)
        if not ca or not cb or not ca["request_cost"] or not cb["request_cost"]:
            return None
        return {
            "p50_delta_ms": ca["request_cost"]["p50_ms"] - cb["request_cost"]["p50_ms"],
            "p95_delta_ms": ca["request_cost"]["p95_ms"] - cb["request_cost"]["p95_ms"],
            "mean_delta_ms": round(
                ca["request_cost"]["mean_ms"] - cb["request_cost"]["mean_ms"], 2),
        }

    report = {
        "cloud": args.cloud,
        "environment": environment,
        "method": {
            "in_webhook_cost": "Kyverno admission_review histogram, "
                               "delta_sum/delta_count summed across replicas; "
                               "undefined for baseline because no webhook runs",
            "request_cost": "client-side wall clock per create request; includes "
                            "constant kubectl startup and network round trip",
            "percentiles": "nearest-rank on observed samples, no interpolation",
            "probe": "unschedulable pods in the policy-matched namespace, so "
                     "admission is exercised without image pull or scheduling",
        },
        "conditions": conditions,
        "comparisons": {
            "enforce_vs_baseline_request_cost": request_delta("enforce", "baseline"),
            "enforce_vs_audit_request_cost": request_delta("enforce", "audit"),
            "audit_vs_baseline_request_cost": request_delta("audit", "baseline"),
        },
    }

    with open(args.out, "w") as fh:
        json.dump(report, fh, indent=2)

    with open(args.csv, "w", newline="") as fh:
        writer = csv.writer(fh)
        writer.writerow([
            "cloud", "condition", "n", "min_ms", "p50_ms", "p95_ms", "p99_ms",
            "max_ms", "mean_ms", "stdev_ms", "rejected",
            "admission_reviews", "in_webhook_ms_per_request",
        ])
        for c in conditions:
            r, w = c["request_cost"], c["in_webhook_cost"]
            if not r:
                writer.writerow([args.cloud, c["condition"], 0, "", "", "", "",
                                 "", "", "", c["rejected_requests"], "", ""])
                continue
            writer.writerow([
                args.cloud, c["condition"], r["n"], r["min_ms"], r["p50_ms"],
                r["p95_ms"], r["p99_ms"], r["max_ms"], r["mean_ms"], r["stdev_ms"],
                c["rejected_requests"],
                w["admission_reviews"] if w else "",
                w["per_request_ms"] if w else "",
            ])

    # ── Console ──────────────────────────────────────────────────────────────
    print("\n" + "=" * 78)
    print(f"  Admission latency — {args.cloud.upper()}")
    print(f"  Kyverno: {environment.get('kyverno_image', 'unknown')}   "
          f"replicas: {environment.get('kyverno_ready_replicas', '?')}")
    print(f"  Probes in namespace: {environment.get('probe_namespace', '?')}")
    print("=" * 78)
    print(f"{'condition':<18}{'n':>4}{'p50':>8}{'p95':>8}{'p99':>8}{'mean':>9}"
          f"{'in-webhook/req':>16}")
    print("-" * 78)
    for c in conditions:
        r, w = c["request_cost"], c["in_webhook_cost"]
        if not r:
            print(f"{c['condition']:<18}{0:>4}   all {c['rejected_requests']} "
                  f"request(s) rejected — the probe image was not admissible")
            continue
        webhook = f"{w['per_request_ms']:.1f} ms" if w else "n/a"
        print(f"{c['condition']:<18}{r['n']:>4}{r['p50_ms']:>7}ms{r['p95_ms']:>7}ms"
              f"{r['p99_ms']:>7}ms{r['mean_ms']:>8.1f}ms{webhook:>16}")
        if w and w["reviews_per_request"] and w["reviews_per_request"] != 1:
            print(f"{'':<18}      ({w['reviews_per_request']:g} admission reviews per "
                  f"request at {w['mean_per_review_ms']:.1f} ms each)")

    print("-" * 78)
    for label, key in [("enforce vs baseline", "enforce_vs_baseline_request_cost"),
                       ("enforce vs audit", "enforce_vs_audit_request_cost")]:
        d = report["comparisons"][key]
        if d:
            print(f"  {label}: p50 {d['p50_delta_ms']:+} ms, "
                  f"p95 {d['p95_delta_ms']:+} ms, mean {d['mean_delta_ms']:+} ms")

    if not any(c["in_webhook_cost"] for c in conditions):
        print("\n  WARNING: no condition produced an in-webhook measurement.")
        print("  Either the probes were not evaluated by any policy, or the")
        print("  metric labels differ from what was filtered on. Check the")
        print("  unfiltered deltas before using any number here.")

    print("=" * 78)
    print(f"  {args.out}\n  {args.csv}")

    # Exit non-zero only when nothing was attempted. A condition whose requests
    # were all rejected has been reported above and is a result in itself.
    if not conditions:
        sys.exit("no requests were recorded — measure-admission.sh did not run, "
                 f"or wrote nothing to {args.results_dir}/requests.csv")


if __name__ == "__main__":
    main()
