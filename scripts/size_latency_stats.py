#!/usr/bin/env python3
"""
Image size vs admission latency statistics.
Reads /tmp/size-latency-raw.csv, prints table, writes /tmp/size-latency-<cloud>.csv
"""
import statistics, os, sys, csv

cloud      = os.environ.get("CLOUD", "unknown")
iterations = os.environ.get("ITERATIONS", "20")
csv_path   = "/tmp/size-latency-raw.csv"

rows   = {}
approx = {}
with open(csv_path) as f:
    reader = csv.DictReader(f)
    for r in reader:
        size = r.get("size", "").strip()
        val  = r.get("latency_ms", "").strip()
        mb   = r.get("approx_mb", "?").strip()
        if not size or not val or not val.lstrip("-").isdigit():
            continue
        rows.setdefault(size, []).append(int(val))
        approx[size] = mb

if not rows:
    print(f"ERROR: no data parsed from {csv_path}")
    sys.exit(1)

print("\n" + "="*70)
print(f"  Image Size vs Admission Latency -- {cloud.upper()}")
print(f"  Hypothesis: latency is flat (Kyverno admission is O(1))")
print("="*70)
print(f"{'size':<10} {'~MB':>6} {'n':>4} {'mean':>8} {'median':>8} {'stdev':>8} {'p95':>8}")
print("-"*70)

results = []
for size in ["small", "medium", "large", "xlarge"]:
    vals = sorted(rows.get(size, []))
    if not vals:
        continue
    mean   = statistics.mean(vals)
    median = statistics.median(vals)
    stdev  = statistics.stdev(vals) if len(vals) > 1 else 0.0
    p95    = vals[min(int(len(vals) * 0.95), len(vals) - 1)]
    mb     = approx.get(size, "?")
    print(f"{size:<10} {mb:>6} {len(vals):>4} {mean:>7.0f}ms {median:>7.0f}ms {stdev:>7.0f}ms {p95:>7.0f}ms")
    results.append((size, mb, len(vals), round(mean), round(median), round(stdev), p95))

if results:
    means  = [r[3] for r in results]
    spread = max(means) - min(means)
    print("-"*70)
    print(f"Mean spread: {spread}ms -- Hypothesis O(1): {'SUPPORTED' if spread < 100 else 'NOT supported'}")
print("="*70)

out = f"/tmp/size-latency-{cloud}.csv"
with open(out, "w") as f:
    f.write("cloud,size,approx_mb,n,mean_ms,median_ms,stdev_ms,p95_ms\n")
    for r in results:
        f.write(f"{cloud},{r[0]},{r[1]},{r[2]},{r[3]},{r[4]},{r[5]},{r[6]}\n")
print(f"CSV saved: {out}")