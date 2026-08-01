#!/usr/bin/env python3
"""
Figures for the admission latency experiments (revision item 1.2).

Replaces generate_charts.py and generate_size_charts.py, which drew grouped bar
charts of mean +/- one standard deviation. Three things were wrong with that:

  * the distributions are bounded below and right-skewed, so a symmetric spread
    around the mean describes a shape the data does not have;
  * "the difference is within one standard deviation" was read as evidence of no
    effect, which is not a test of anything -- and the effect is real (p =
    0.0011 on the corrected data);
  * they plotted the pre-correction measurements, in which every probe ran in a
    namespace the policies do not match, so no verification occurred at all.

What is drawn instead, per experiment:

  ECDF     the full distribution as a step function. Every request that
           happened is on the chart, so the reader sees the shape and the tail
           rather than a summary of them.
  violin   the same samples as a density with the raw observations overlaid.
           At n = 30 per condition the individual points are worth showing:
           they are what the outlier discussion in the size experiment is about.

Statistics are imported from latency_analysis.py, never recomputed here. That
module is the one that was cross-checked against SciPy, and a second
implementation of the same test is a second thing to keep correct.

Colour: four categorical hues validated for colour-vision deficiency and for
normal-vision separation (all-pairs, light surface). Line style and marker carry
the same distinction independently, so the figures survive greyscale printing --
which is how a submitted dissertation is often read.

Usage:
    python3 scripts/latency_charts.py \\
        --requests results/latency/aws-30692789440/latency-requests-aws.csv \\
        --preset policy --out results/latency/admission-latency-policy

    python3 scripts/latency_charts.py \\
        --requests results/latency/aws-30692789440/size-requests-aws.csv \\
        --preset size --out results/latency/admission-latency-size

Writes <out>.png and <out>.pdf. The PDF is the one to \\includegraphics.
"""
import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import latency_analysis as la  # noqa: E402  the statistics live there, not here

try:
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    import numpy as np
except ImportError:
    sys.exit("matplotlib and numpy are required: pip install matplotlib numpy")


# ── Presentation constants ───────────────────────────────────────────────────
# Categorical slots 1, 2, 3 and 7 of the reference palette. Validated all-pairs
# on the light surface: worst CVD dE 9.2 (deutan), worst normal-vision dE 16.3,
# both clear of their floors. The aqua slot sits below 3:1 against the surface,
# so the series are also direct-labelled -- which is the documented relief and
# is wanted here anyway.
SERIES_COLOURS = ["#2a78d6", "#eb6834", "#1baf7a", "#4a3aa7"]
DASHES = [(None, None), (5, 2), (1.6, 1.6), (7, 2, 1.6, 2)]
MARKERS = ["o", "s", "^", "D"]

INK = "#0b0b0b"
INK_SECONDARY = "#52514e"
INK_MUTED = "#898781"
GRID = "#e1e0d9"
AXIS = "#c3c2b7"

PRESETS = {
    "policy": {
        "order": ["baseline", "audit", "enforce"],
        "labels": {"baseline": "baseline (no policies)",
                   "audit": "audit", "enforce": "enforce"},
        "title": "Admission request latency by policy condition",
        "headline": ("enforce", "baseline"),
    },
    "size": {
        "order": ["size-small", "size-medium", "size-large", "size-xlarge"],
        "labels": {"size-small": "small", "size-medium": "medium",
                   "size-large": "large", "size-xlarge": "xlarge"},
        "title": "Admission request latency by image size",
        # Deliberately NOT xlarge vs small. In run 30692789440 the size
        # conditions ran in fixed ascending order, so `small` absorbed session
        # warm-up and every comparison against it comes out significant with the
        # larger image faster -- a direction no mechanism can produce (D17).
        # changes.md 0.0.2 states plainly that this must not be reported as a
        # finding, so the figure must not headline it either. xlarge vs medium is
        # the widest span among the size-adjacent conditions, which is the
        # comparison that actually tests the hypothesis.
        "headline": ("size-xlarge", "size-medium"),
    },
}

FOOTNOTE = ("Absolute values include kubectl start-up and the runner-to-API-server "
            "round trip; only differences between conditions are attributable to admission.")


def ordered_samples(samples, order):
    """Canonical order regardless of the order the conditions were measured in.

    The size experiment randomises its execution order (D17), so the order in
    the CSV varies between runs. Tables and figures must not move with it.
    """
    known = [c for c in order if c in samples]
    extra = [c for c in samples if c not in order]
    if extra:
        print(f"note: conditions not in the preset, appended as-is: {extra}",
              file=sys.stderr)
    return [(c, samples[c]) for c in known + extra]


def draw(samples, preset, out_base, provenance):
    conditions = ordered_samples(samples, preset["order"])
    if not conditions:
        sys.exit("none of the preset's conditions are present in the CSV")

    fig, (ax_ecdf, ax_dist) = plt.subplots(
        1, 2, figsize=(10.6, 4.4), gridspec_kw={"width_ratios": [1.55, 1]})

    # ── ECDF ────────────────────────────────────────────────────────────────
    for i, (condition, values) in enumerate(conditions):
        points = la.ecdf_points(values)
        xs = [p[0] for p in points]
        ys = [p[1] for p in points]
        colour = SERIES_COLOURS[i % len(SERIES_COLOURS)]
        label = preset["labels"].get(condition, condition)
        ax_ecdf.step(xs, ys, where="post", color=colour, linewidth=2.0,
                     dashes=DASHES[i % len(DASHES)],
                     label=f"{label} (n={len(values)})", zorder=3)
        # p50 marker: a single point per series, not a number on every point.
        p50 = la.percentile(sorted(values), 0.50)
        ax_ecdf.plot([p50], [0.5], marker=MARKERS[i % len(MARKERS)],
                     markersize=8, color=colour, markeredgecolor="#fcfcfb",
                     markeredgewidth=1.5, linestyle="none", zorder=4)

    # ── Keep the tail from owning the x-axis, without hiding it ─────────────
    # In the size experiment two requests of ~3.35 s sit against a ~2.1 s
    # median. Left to set the scale they compress every distribution into the
    # first eighth of the panel and the comparison the figure exists to show
    # becomes invisible. They are also the most interesting observations in the
    # run -- the evidence that the tail lives in the imageVerify rules, i.e. in
    # Rekor and the registry -- so they are not dropped: the axis is clipped,
    # the number and size of the off-scale requests is stated on the figure, and
    # the right-hand panel still plots every observation on an unclipped scale.
    # The reference is the widest per-condition p95 -- the same statistic the
    # results tables report -- not a pooled quantile: pooled quantiles land on
    # the outliers themselves once the tail is heavy enough, which is exactly
    # when the clip is needed. Clip only when the extreme is far outside that
    # reference, so the policy matrix (max 2287 ms against a p95 of 2171) is
    # left untouched and only a genuinely long tail is folded.
    pooled = sorted(v for _, values in conditions for v in values)
    p95_ref = max(la.percentile(sorted(values), 0.95) for _, values in conditions)
    clip_note = ""
    if pooled[-1] > p95_ref * 1.25:
        right_edge = p95_ref * 1.04
        beyond = [v for v in pooled if v > right_edge]
        ax_ecdf.set_xlim(pooled[0] - 20, right_edge)
        # Stated in the footnote rather than inside the panel, where it landed
        # on the legend.
        clip_note = (f" ECDF clipped at {right_edge:.0f} ms: {len(beyond)} of "
                     f"{len(pooled)} requests lie beyond it (max {pooled[-1]} ms) "
                     f"and are plotted in full at right.")

    ax_ecdf.set_ylim(0, 1.02)
    ax_ecdf.set_ylabel("cumulative proportion of requests", color=INK_SECONDARY)
    ax_ecdf.set_xlabel("client-observed admission request latency (ms)",
                       color=INK_SECONDARY)
    ax_ecdf.grid(alpha=0.35, color=GRID, linewidth=0.8)
    ax_ecdf.set_axisbelow(True)
    legend = ax_ecdf.legend(loc="lower right", frameon=False, fontsize=9)
    for text in legend.get_texts():
        text.set_color(INK_SECONDARY)
    ax_ecdf.set_title("Distribution (ECDF), marker at p50", fontsize=10,
                      color=INK, loc="left", pad=8)

    # ── Violin with the raw observations ────────────────────────────────────
    data = [values for _, values in conditions]
    positions = list(range(1, len(data) + 1))
    parts = ax_dist.violinplot(data, positions=positions, widths=0.75,
                               showextrema=False, showmedians=False)
    for i, body in enumerate(parts["bodies"]):
        body.set_facecolor(SERIES_COLOURS[i % len(SERIES_COLOURS)])
        body.set_alpha(0.22)
        body.set_edgecolor(SERIES_COLOURS[i % len(SERIES_COLOURS)])
        body.set_linewidth(1.2)

    rng = np.random.default_rng(0)   # jitter is cosmetic, so it is deterministic
    for i, (condition, values) in enumerate(conditions):
        colour = SERIES_COLOURS[i % len(SERIES_COLOURS)]
        jitter = rng.uniform(-0.13, 0.13, size=len(values))
        ax_dist.plot(np.full(len(values), positions[i]) + jitter, values,
                     marker=MARKERS[i % len(MARKERS)], linestyle="none",
                     markersize=4.5, color=colour, alpha=0.75,
                     markeredgecolor="none", zorder=3)
        ordered = sorted(values)
        p50 = la.percentile(ordered, 0.50)
        p95 = la.percentile(ordered, 0.95)
        ax_dist.hlines(p50, positions[i] - 0.34, positions[i] + 0.34,
                       color=colour, linewidth=2.4, zorder=4)
        ax_dist.hlines(p95, positions[i] - 0.22, positions[i] + 0.22,
                       color=colour, linewidth=1.2, linestyles=(0, (2, 2)),
                       zorder=4)
        # Centred above the median line rather than beside it: placed to the
        # right it collided with the next violin.
        ax_dist.annotate(f"p50 {p50}", xy=(positions[i], p50),
                         xytext=(0, 7), textcoords="offset points",
                         fontsize=8, color=INK_SECONDARY,
                         va="bottom", ha="center",
                         bbox=dict(facecolor="#fcfcfb", edgecolor="none",
                                   alpha=0.85, pad=1.5))

    ax_dist.set_xticks(positions)
    ax_dist.set_xticklabels([preset["labels"].get(c, c) for c, _ in conditions],
                            fontsize=9, color=INK_SECONDARY)
    ax_dist.set_ylabel("latency (ms)", color=INK_SECONDARY)
    ax_dist.grid(alpha=0.35, axis="y", color=GRID, linewidth=0.8)
    ax_dist.set_axisbelow(True)
    ax_dist.set_title("Every observation, with p50 and p95", fontsize=10,
                      color=INK, loc="left", pad=8)

    for ax in (ax_ecdf, ax_dist):
        for spine in ("top", "right"):
            ax.spines[spine].set_visible(False)
        for spine in ("left", "bottom"):
            ax.spines[spine].set_color(AXIS)
        ax.tick_params(colors=INK_MUTED, labelsize=9)

    # ── Headline comparison, computed not typed ─────────────────────────────
    right, left = preset["headline"]
    subtitle = ""
    if right in samples and left in samples:
        test = la.mann_whitney(samples[right], samples[left])
        shift = la.hodges_lehmann(samples[right], samples[left])
        if test:
            verdict = ("differ" if test["p_value"] < 0.05
                       else "no detectable difference")
            subtitle = (f"{right} vs {left}: median shift {shift:+.0f} ms, "
                        f"p = {test['p_value']:.3g}, "
                        f"rank-biserial {test['rank_biserial']:.2f} ({verdict})")

    fig.suptitle(preset["title"], fontsize=12.5, color=INK, x=0.008, ha="left",
                 y=0.975)
    if subtitle:
        fig.text(0.008, 0.906, subtitle, fontsize=9.5, color=INK_SECONDARY,
                 ha="left")
    # Two footnote lines: the clip note is long enough that keeping it on the
    # same line ran it into the provenance stamp on the right.
    fig.text(0.008, 0.048, FOOTNOTE, fontsize=7.5, color=INK_MUTED, ha="left")
    fig.text(0.992, 0.048, provenance, fontsize=7.5, color=INK_MUTED, ha="right")
    if clip_note:
        fig.text(0.008, 0.014, clip_note.strip(), fontsize=7.5,
                 color=INK_MUTED, ha="left")

    fig.tight_layout(rect=(0, 0.075, 1, 0.878))

    written = []
    for ext in ("png", "pdf"):
        path = f"{out_base}.{ext}"
        fig.savefig(path, dpi=220, facecolor="#fcfcfb")
        written.append(path)
    plt.close(fig)
    return written, conditions


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--requests", required=True,
                    help="per-request CSV (requests.csv / *-requests-*.csv)")
    ap.add_argument("--preset", required=True, choices=sorted(PRESETS))
    ap.add_argument("--out", required=True, help="output path without extension")
    ap.add_argument("--provenance", default="",
                    help="run id or artefact path drawn on the figure; "
                         "defaults to the source file name")
    args = ap.parse_args()

    samples = la.read_samples(args.requests)
    provenance = args.provenance or f"source: {os.path.basename(args.requests)}"

    written, conditions = draw(samples, PRESETS[args.preset], args.out, provenance)

    print(f"{args.preset}: {len(conditions)} conditions, "
          f"{sum(len(v) for _, v in conditions)} accepted requests")
    for condition, values in conditions:
        d = la.describe(values)
        print(f"  {condition:<14} n={d['n']:<4} p50={d['p50_ms']}ms  "
              f"p95={d['p95_ms']}ms  p99={d['p99_ms']}ms  IQR={d['iqr_ms']}ms")
    for path in written:
        print(f"written: {path}")


if __name__ == "__main__":
    main()
