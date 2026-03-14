#!/usr/bin/env python3
"""
Generates image size vs admission latency charts from Phase 4b data.

Usage:
    # Download the size-latency-aws and size-latency-azure artifacts from
    # the 'Measure Admission Latency' GitHub Actions run, then:
    python3 docs/generate_size_charts.py size-latency-aws.csv size-latency-azure.csv

Output:
    docs/figures/size_vs_latency.png
    docs/figures/size_vs_latency.pdf  (for LaTeX)

The script produces a line chart showing admission latency across four
image sizes (5MB / 30MB / 120MB / 400MB) for both AWS EKS and Azure AKS.
A flat line across sizes confirms the O(1) hypothesis — Kyverno verifies
the image digest against Rekor without pulling image content, so image
size does not affect admission cost.

This figure goes in the Performance Evaluation chapter alongside the
overhead chart to show that the framework scales to any image size.
"""
import sys
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


def load_csv(path: str) -> list:
    """Read a size-latency CSV into a list of dicts ordered by image size."""
    rows = []
    with open(path) as f:
        reader = csv.DictReader(f)
        for row in reader:
            rows.append({
                "size":   row["size"],
                "mb":     int(row["approx_mb"]),
                "mean":   int(row["mean_ms"]),
                "median": int(row["median_ms"]),
                "stdev":  int(row["stdev_ms"]),
                "cloud":  row["cloud"],
            })
    # Sort by image size so the x-axis is monotonically increasing
    return sorted(rows, key=lambda r: r["mb"])


def main():
    if len(sys.argv) < 3:
        print("Usage: generate_size_charts.py size-latency-aws.csv size-latency-azure.csv")
        sys.exit(1)

    aws_rows   = load_csv(sys.argv[1])
    azure_rows = load_csv(sys.argv[2])

    aws_mb     = [r["mb"]    for r in aws_rows]
    aws_means  = [r["mean"]  for r in aws_rows]
    aws_stdevs = [r["stdev"] for r in aws_rows]
    aws_labels = [r["size"]  for r in aws_rows]

    azure_mb     = [r["mb"]    for r in azure_rows]
    azure_means  = [r["mean"]  for r in azure_rows]
    azure_stdevs = [r["stdev"] for r in azure_rows]

    fig, ax = plt.subplots(figsize=(9, 5))

    ax.errorbar(aws_mb, aws_means, yerr=aws_stdevs,
                label="AWS EKS", color="#FF9900", marker="o",
                linewidth=2, capsize=5, markersize=7)
    ax.errorbar(azure_mb, azure_means, yerr=azure_stdevs,
                label="Azure AKS", color="#0072C6", marker="s",
                linewidth=2, capsize=5, markersize=7)

    ax.set_xlabel("Image size (MB)", fontsize=12)
    ax.set_ylabel("Admission latency (ms)", fontsize=12)
    ax.set_title("Image Size vs Kyverno Admission Latency\n"
                 "(error bars = 1 standard deviation, n=20 per size)",
                 fontsize=12)
    ax.set_xscale("log")
    ax.set_xticks(aws_mb)
    ax.set_xticklabels([f"{s}\n({m}MB)" for s, m in zip(aws_labels, aws_mb)],
                       fontsize=10)
    ax.legend(fontsize=11)
    ax.grid(axis="y", linestyle="--", alpha=0.4)
    ax.set_ylim(0)

    # Print the spread for each cloud so it appears in terminal output
    for cloud, rows in [("AWS", aws_rows), ("Azure", azure_rows)]:
        means  = [r["mean"] for r in rows]
        spread = max(means) - min(means)
        verdict = "SUPPORTED" if spread < 500 else "inconclusive"
        print(f"{cloud}: spread={spread}ms across all sizes — O(1) hypothesis {verdict}")

    out_dir = Path("docs/figures")
    out_dir.mkdir(parents=True, exist_ok=True)

    fig.tight_layout()
    fig.savefig(out_dir / "size_vs_latency.png", dpi=150)
    fig.savefig(out_dir / "size_vs_latency.pdf")
    print(f"\nSaved to {out_dir}/size_vs_latency.{{png,pdf}}")


if __name__ == "__main__":
    main()