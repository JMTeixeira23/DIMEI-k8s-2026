#!/usr/bin/env python3
"""
Generates admission latency charts from Phase 4 measurement data.

Usage:
    # Download the latency-aws and latency-azure artifacts from the
    # 'Measure Admission Latency' GitHub Actions run, then:
    python3 docs/generate_charts.py latency-aws.csv latency-azure.csv

Output:
    docs/figures/admission_latency_overhead.png
    docs/figures/admission_latency_overhead.pdf  (for LaTeX)

The script produces a grouped bar chart comparing admission latency
across three policy conditions (baseline / audit / enforce) for both
AWS EKS and Azure AKS. Error bars show one standard deviation.

This figure goes in the Performance Evaluation chapter to support the
claim that Kyverno adds negligible overhead (~0ms) to pod admission.
"""
import sys
import os
import csv
from pathlib import Path

try:
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    import numpy as np
except ImportError:
    print("Install dependencies: pip install matplotlib numpy")
    sys.exit(1)


def load_csv(path: str) -> dict:
    """Read a latency CSV into a dict keyed by condition."""
    data = {}
    with open(path) as f:
        reader = csv.DictReader(f)
        for row in reader:
            cond = row["condition"]
            data[cond] = {
                "mean":   int(row["mean_ms"]),
                "median": int(row["median_ms"]),
                "stdev":  int(row["stdev_ms"]),
                "p95":    int(row["p95_ms"]),
                "n":      int(row["n"]),
                "cloud":  row["cloud"],
            }
    return data


def main():
    if len(sys.argv) < 3:
        print("Usage: generate_charts.py latency-aws.csv latency-azure.csv")
        sys.exit(1)

    aws_data   = load_csv(sys.argv[1])
    azure_data = load_csv(sys.argv[2])

    conditions = ["baseline", "audit", "enforce"]
    labels     = ["Baseline\n(no policies)", "Audit mode", "Enforce mode"]

    aws_means   = [aws_data[c]["mean"]   for c in conditions]
    aws_stdevs  = [aws_data[c]["stdev"]  for c in conditions]
    azure_means = [azure_data[c]["mean"] for c in conditions]
    azure_stdevs= [azure_data[c]["stdev"]for c in conditions]

    x     = np.arange(len(conditions))
    width = 0.35

    fig, ax = plt.subplots(figsize=(9, 5))

    bars_aws   = ax.bar(x - width/2, aws_means,   width, yerr=aws_stdevs,
                        label="AWS EKS",   color="#FF9900", alpha=0.85,
                        capsize=5, error_kw={"linewidth": 1.2})
    bars_azure = ax.bar(x + width/2, azure_means, width, yerr=azure_stdevs,
                        label="Azure AKS", color="#0072C6", alpha=0.85,
                        capsize=5, error_kw={"linewidth": 1.2})

    ax.set_xlabel("Policy condition", fontsize=12)
    ax.set_ylabel("Admission latency (ms)", fontsize=12)
    ax.set_title("Kyverno Admission Latency — Baseline vs Audit vs Enforce\n"
                 "(error bars = 1 standard deviation, n=30 per condition)",
                 fontsize=12)
    ax.set_xticks(x)
    ax.set_xticklabels(labels, fontsize=11)
    ax.legend(fontsize=11)
    ax.grid(axis="y", linestyle="--", alpha=0.4)
    ax.set_ylim(0)

    # Annotate each bar with its mean value
    for bar in bars_aws + bars_azure:
        h = bar.get_height()
        ax.text(bar.get_x() + bar.get_width() / 2., h + 50,
                f"{h:,}ms", ha="center", va="bottom", fontsize=8)

    # Print the overhead numbers so they appear in the figure caption
    for cloud, data in [("AWS", aws_data), ("Azure", azure_data)]:
        baseline = data["baseline"]["mean"]
        enforce  = data["enforce"]["mean"]
        overhead = enforce - baseline
        pct      = overhead / baseline * 100
        print(f"{cloud}: baseline={baseline}ms  enforce={enforce}ms  "
              f"overhead={overhead:+d}ms ({pct:+.1f}%)")

    out_dir = Path("docs/figures")
    out_dir.mkdir(parents=True, exist_ok=True)

    fig.tight_layout()
    fig.savefig(out_dir / "admission_latency_overhead.png", dpi=150)
    fig.savefig(out_dir / "admission_latency_overhead.pdf")
    print(f"\nSaved to {out_dir}/admission_latency_overhead.{{png,pdf}}")


if __name__ == "__main__":
    main()