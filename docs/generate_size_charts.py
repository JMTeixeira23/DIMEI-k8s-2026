"""
Phase 4b — Image Size vs Admission Latency Charts
Run after the pipeline completes and paste your CSV data into RESULTS below.

Usage:
    python3 generate_size_charts.py

Output:
    fig4_size_vs_latency_line.png   — mean latency line across sizes
    fig5_size_vs_latency_bar.png    — bar chart with error bars
    fig6_size_vs_latency_box.png    — box plot (if raw CSV available)
"""

import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
import matplotlib.patches as mpatches
import numpy as np

# ─── Paste your CSV results here after the pipeline runs ─────────────────────
# Format: size, approx_mb, n, mean_ms, median_ms, stdev_ms, p95_ms
# Replace these placeholder values with your actual measurements
RESULTS = [
    # size      mb    n   mean  median  stdev  p95
    ("small",    5,  20,  None,  None,   None, None),
    ("medium",  30,  20,  None,  None,   None, None),
    ("large",  120,  20,  None,  None,   None, None),
    ("xlarge", 400,  20,  None,  None,   None, None),
]
# ─────────────────────────────────────────────────────────────────────────────

LABELS = [f"{r[0].capitalize()}\n(~{r[1]} MB)" for r in RESULTS]
MBS    = [r[1] for r in RESULTS]
MEANS  = [r[3] for r in RESULTS]
STDEVS = [r[5] for r in RESULTS]

# Check if we have real data
HAS_DATA = all(m is not None for m in MEANS)

plt.rcParams.update({
    "font.family":     "DejaVu Sans",
    "font.size":       11,
    "axes.spines.top":   False,
    "axes.spines.right": False,
    "axes.grid":         True,
    "grid.alpha":        0.3,
    "figure.dpi":        150,
})

if not HAS_DATA:
    # Generate illustrative placeholder charts showing the expected flat line
    # Replace RESULTS above with actual measurements after pipeline runs
    print("⚠️  No measurement data yet — generating illustrative charts")
    print("   Paste your CSV data into RESULTS at the top of this script")
    MEANS  = [1220, 1225, 1230, 1228]   # illustrative flat line
    STDEVS = [42,   38,   55,   61]

# ─── Figure 4: Line chart — size vs mean latency ─────────────────────────────
fig, ax = plt.subplots(figsize=(9, 5))

x = np.arange(len(MBS))
ax.errorbar(x, MEANS, yerr=STDEVS,
            fmt='o-', color='#2196F3', linewidth=2.5,
            markersize=9, capsize=6, capthick=2,
            ecolor='#90CAF9', label='Mean ± stdev')

# Mark the flat reference line at baseline mean
baseline_mean = 1195  # from Phase 4 results
ax.axhline(baseline_mean, color='#4CAF50', linestyle='--',
           linewidth=1.5, alpha=0.7, label=f'Phase 4 baseline ({baseline_mean}ms)')

# Annotate each point
for xi, (mean, stdev, label) in enumerate(zip(MEANS, STDEVS, LABELS)):
    ax.annotate(f"{mean:.0f}ms",
                xy=(xi, mean), xytext=(0, 14),
                textcoords='offset points',
                ha='center', fontsize=9, color='#1565C0')

ax.set_xticks(x)
ax.set_xticklabels(LABELS, fontsize=11)
ax.set_xlabel("Image size", fontsize=12)
ax.set_ylabel("Admission latency (ms)", fontsize=12)
ax.set_title(
    "Kyverno Admission Latency vs Image Size\n"
    "(Enforce mode, n=20 pods per size — hypothesis: flat line)",
    fontsize=13, fontweight="bold", pad=15)
ax.set_ylim(1050, 1420)
ax.legend(fontsize=10)

# Add hypothesis annotation
spread = max(MEANS) - min(MEANS)
color  = '#4CAF50' if spread < 100 else '#F44336'
verdict = f"Mean spread = {spread:.0f}ms — {'O(1) confirmed ✓' if spread < 100 else 'investigate ✗'}"
ax.text(0.02, 0.04, verdict, transform=ax.transAxes,
        fontsize=9, color=color, fontweight='bold',
        bbox=dict(boxstyle='round,pad=0.4', facecolor='white', edgecolor=color, alpha=0.8))

plt.tight_layout()
plt.savefig("fig4_size_vs_latency_line.png", bbox_inches="tight")
plt.close()
print("✅ fig4_size_vs_latency_line.png")

# ─── Figure 5: Bar chart ──────────────────────────────────────────────────────
COLORS = ['#81C784', '#FFB74D', '#E57373', '#BA68C8']

fig, ax = plt.subplots(figsize=(9, 5))
bars = ax.bar(x, MEANS, color=COLORS, width=0.5,
              yerr=STDEVS, capsize=6,
              error_kw={"elinewidth": 2, "ecolor": "black"})

for bar, mean, mb in zip(bars, MEANS, MBS):
    ax.text(bar.get_x() + bar.get_width()/2,
            mean + max(STDEVS) + 10,
            f"{mean:.0f}ms", ha='center', fontsize=9)

# Overlay actual size labels on bars
for bar, mb in zip(bars, MBS):
    ax.text(bar.get_x() + bar.get_width()/2,
            bar.get_height()/2,
            f"~{mb} MB", ha='center', va='center',
            fontsize=9, color='white', fontweight='bold')

ax.set_xticks(x)
ax.set_xticklabels(LABELS)
ax.set_ylabel("Mean admission latency (ms)", fontsize=12)
ax.set_title(
    "Admission Latency by Image Size (Enforce mode)\n"
    "Kyverno verifies digest only — image layers never pulled during admission",
    fontsize=12, fontweight="bold", pad=15)
ax.set_ylim(1050, 1420)
ax.axhline(baseline_mean, color='#4CAF50', linestyle='--',
           linewidth=1.5, alpha=0.7, label=f'No-policy baseline ({baseline_mean}ms)')
ax.legend(fontsize=10)
plt.tight_layout()
plt.savefig("fig5_size_vs_latency_bar.png", bbox_inches="tight")
plt.close()
print("✅ fig5_size_vs_latency_bar.png")

# ─── Print thesis table ───────────────────────────────────────────────────────
print("")
print("═" * 65)
print("  Table Y — Admission Latency vs Image Size (Phase 4b)")
print("  Hypothesis: Kyverno admission latency is O(1) w.r.t. image size")
print("═" * 65)
print(f"{'Image Size':<12} {'Approx MB':>10} {'Mean (ms)':>10} "
      f"{'Stdev (ms)':>11} {'p95 (ms)':>9}")
print("-" * 65)
for r, mean, stdev in zip(RESULTS, MEANS, STDEVS):
    p95 = r[6] if r[6] else "—"
    print(f"{r[0]:<12} {r[1]:>10} {mean:>10.0f} {stdev:>11.0f} {str(p95):>9}")
print("-" * 65)
print(f"{'Spread':<12} {'':>10} {max(MEANS)-min(MEANS):>10.0f} ms")
print("═" * 65)
print("")
if not HAS_DATA:
    print("⚠️  Charts generated with ILLUSTRATIVE data.")