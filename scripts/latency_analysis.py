#!/usr/bin/env python3
"""
Distribution and significance analysis of admission latency samples.

Replaces the mean ± standard deviation summary that the earlier statistics
script produced. Two reasons that summary was the wrong tool: admission latency
is bounded below and right-skewed, so the mean sits above the typical request
and the standard deviation implies a symmetric spread that does not exist; and
"the difference is within one standard deviation" is not a test of anything.

What this does instead:

  percentiles     p50/p95/p99 by nearest rank on the observed samples. Every
                  reported value is a request that actually happened.
  Mann-Whitney U  a rank test of whether one condition's requests are
                  stochastically larger than another's. It assumes nothing about
                  the shape of the distributions, which matters here because
                  they are not normal.
  effect size     rank-biserial correlation, and the Hodges-Lehmann median of
                  pairwise differences in milliseconds. A p-value says an effect
                  exists; these say how big it is, which is the question a
                  reader of the performance chapter actually has.
  ECDF            the full distribution as a step function, so the comparison
                  can be seen rather than summarised.

Implemented against the standard library only — no SciPy on the runner. The U
statistic uses the normal approximation with a continuity correction and a tie
correction, which is appropriate at n = 30 per group and is stated in the output
so the reader knows what was computed.

Usage:
    python3 scripts/latency_analysis.py requests.csv --baseline baseline --compare enforce
    python3 scripts/latency_analysis.py requests.csv --all-pairs --json out.json
    python3 scripts/latency_analysis.py requests.csv --ecdf ecdf.png
"""
import argparse
import csv
import itertools
import json
import math
import statistics
import sys
from collections import OrderedDict


def read_samples(path):
    samples = OrderedDict()
    with open(path) as fh:
        for row in csv.DictReader(fh):
            if row.get("accepted") != "true":
                continue
            samples.setdefault(row["condition"], []).append(int(row["client_ms"]))
    if not samples:
        sys.exit(f"no accepted requests found in {path}")
    return samples


def percentile(ordered, fraction):
    rank = max(1, min(len(ordered), math.ceil(fraction * len(ordered))))
    return ordered[rank - 1]


def describe(values):
    ordered = sorted(values)
    return {
        "n": len(ordered),
        "min_ms": ordered[0],
        "p50_ms": percentile(ordered, 0.50),
        "p95_ms": percentile(ordered, 0.95),
        "p99_ms": percentile(ordered, 0.99),
        "max_ms": ordered[-1],
        "mean_ms": round(statistics.mean(ordered), 2),
        "iqr_ms": percentile(ordered, 0.75) - percentile(ordered, 0.25),
    }


def rank_with_ties(values):
    """Average ranks, as Mann-Whitney requires when values repeat."""
    indexed = sorted(range(len(values)), key=lambda i: values[i])
    ranks = [0.0] * len(values)
    i = 0
    tie_groups = []
    while i < len(indexed):
        j = i
        while j + 1 < len(indexed) and values[indexed[j + 1]] == values[indexed[i]]:
            j += 1
        average = (i + j + 2) / 2.0        # ranks are 1-based
        for k in range(i, j + 1):
            ranks[indexed[k]] = average
        if j > i:
            tie_groups.append(j - i + 1)
        i = j + 1
    return ranks, tie_groups


def mann_whitney(a, b):
    """Two-sided Mann-Whitney U, normal approximation with tie correction.

    Returns U for `a`, the z statistic, the two-sided p-value, and the
    rank-biserial correlation as the effect size.
    """
    n1, n2 = len(a), len(b)
    if n1 == 0 or n2 == 0:
        return None

    ranks, tie_groups = rank_with_ties(list(a) + list(b))
    r1 = sum(ranks[:n1])
    u1 = r1 - n1 * (n1 + 1) / 2.0
    u2 = n1 * n2 - u1

    mu = n1 * n2 / 2.0
    n = n1 + n2
    tie_term = sum(t ** 3 - t for t in tie_groups)
    variance = (n1 * n2 / 12.0) * ((n + 1) - tie_term / (n * (n - 1)))
    if variance <= 0:
        return None
    u = min(u1, u2)
    z = (u - mu + 0.5) / math.sqrt(variance)          # continuity correction
    # Two-sided p for a standard normal: P(|Z| > |z|) = erfc(|z| / sqrt(2)).
    p = min(1.0, max(0.0, math.erfc(abs(z) / math.sqrt(2))))

    return {
        "u_statistic": u1,
        "z": round(z, 4),
        "p_value": p,
        "rank_biserial": round(2.0 * u1 / (n1 * n2) - 1.0, 4),
        "ties_present": bool(tie_groups),
        "method": "normal approximation, continuity and tie corrected",
    }


def hodges_lehmann(a, b):
    """Median of all pairwise differences — the shift the U test detects."""
    diffs = sorted(x - y for x, y in itertools.product(a, b))
    return statistics.median(diffs) if diffs else None


def ecdf_points(values):
    ordered = sorted(values)
    n = len(ordered)
    return [(v, (i + 1) / n) for i, v in enumerate(ordered)]


def write_ecdf(samples, path):
    try:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
    except ImportError:
        print(f"matplotlib not installed — skipping {path}", file=sys.stderr)
        return False

    fig, ax = plt.subplots(figsize=(7, 4.2))
    for condition, values in samples.items():
        xs = [p[0] for p in ecdf_points(values)]
        ys = [p[1] for p in ecdf_points(values)]
        ax.step(xs, ys, where="post", label=f"{condition} (n={len(values)})")
    ax.set_xlabel("admission request latency (ms)")
    ax.set_ylabel("cumulative proportion of requests")
    ax.set_ylim(0, 1.02)
    ax.grid(alpha=0.3)
    ax.legend()
    fig.tight_layout()
    fig.savefig(path, dpi=200)
    print(f"ECDF written to {path}")
    return True


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("csv_path")
    ap.add_argument("--baseline", default="baseline")
    ap.add_argument("--compare", action="append", default=[])
    ap.add_argument("--all-pairs", action="store_true")
    ap.add_argument("--json")
    ap.add_argument("--ecdf")
    ap.add_argument("--alpha", type=float, default=0.05)
    args = ap.parse_args()

    samples = read_samples(args.csv_path)

    print("=" * 74)
    print("  Admission request latency — distribution")
    print("=" * 74)
    print(f"{'condition':<18}{'n':>4}{'min':>8}{'p50':>8}{'p95':>8}{'p99':>8}"
          f"{'max':>8}{'IQR':>8}")
    print("-" * 74)
    summary = {}
    for condition, values in samples.items():
        d = describe(values)
        summary[condition] = d
        print(f"{condition:<18}{d['n']:>4}{d['min_ms']:>7}ms{d['p50_ms']:>7}ms"
              f"{d['p95_ms']:>7}ms{d['p99_ms']:>7}ms{d['max_ms']:>7}ms"
              f"{d['iqr_ms']:>7}ms")

    if args.all_pairs:
        pairs = list(itertools.combinations(samples.keys(), 2))
    else:
        targets = args.compare or [c for c in samples if c != args.baseline]
        pairs = [(args.baseline, c) for c in targets if c in samples]

    print()
    print("=" * 74)
    print("  Mann-Whitney U, two-sided")
    print("=" * 74)

    comparisons = {}
    for left, right in pairs:
        if left not in samples or right not in samples:
            continue
        test = mann_whitney(samples[right], samples[left])
        if not test:
            continue
        shift = hodges_lehmann(samples[right], samples[left])
        key = f"{right}_vs_{left}"
        comparisons[key] = {
            **test,
            "hodges_lehmann_shift_ms": shift,
            "p50_delta_ms": summary[right]["p50_ms"] - summary[left]["p50_ms"],
            "p95_delta_ms": summary[right]["p95_ms"] - summary[left]["p95_ms"],
            "significant_at_alpha": test["p_value"] < args.alpha,
        }
        verdict = ("distributions differ" if test["p_value"] < args.alpha
                   else "no detectable difference")
        print(f"  {right} vs {left}")
        print(f"    U = {test['u_statistic']:.1f}   z = {test['z']}   "
              f"p = {test['p_value']:.3g}   ({verdict} at alpha={args.alpha})")
        print(f"    rank-biserial = {test['rank_biserial']}   "
              f"median shift = {shift:+.1f} ms   "
              f"p50 {comparisons[key]['p50_delta_ms']:+} ms   "
              f"p95 {comparisons[key]['p95_delta_ms']:+} ms")

    if args.ecdf:
        write_ecdf(samples, args.ecdf)

    if args.json:
        with open(args.json, "w") as fh:
            json.dump({
                "method": {
                    "percentiles": "nearest rank, no interpolation",
                    "test": "Mann-Whitney U, two-sided, normal approximation "
                            "with continuity and tie correction",
                    "effect_size": "rank-biserial correlation; Hodges-Lehmann "
                                   "median of pairwise differences in ms",
                },
                "summary": summary,
                "comparisons": comparisons,
            }, fh, indent=2)
        print(f"\nwritten to {args.json}")


if __name__ == "__main__":
    main()
