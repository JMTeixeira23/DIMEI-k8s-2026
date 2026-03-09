#!/usr/bin/env python3
"""
Admission latency statistics — baseline / audit / enforce.
Reads /tmp/all-raw.csv, prints table, writes /tmp/latency-<cloud>.csv
"""
import statistics, os, sys

cloud      = os.environ.get("CLOUD", "unknown")
iterations = os.environ.get("ITERATIONS", "30")
csv_path   = "/tmp/all-raw.csv"

rows = {}
with open(csv_path) as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        parts = line.split(",")
        if len(parts) != 2:
            continue
        cond, val = parts[0].strip(), parts[1].strip()
        if not val.lstrip("-").isdigit():
            continue
        rows.setdefault(cond, []).append(int(val))

if not rows:
    print(f"ERROR: no data rows parsed from {csv_path}")
    sys.exit(1)

print("\n" + "="*65)
print(f"  Admission Latency -- {cloud.upper()} (n={iterations})")
print("="*65)
print(f"{'condition':<12} {'n':>4} {'mean':>8} {'median':>8} {'stdev':>8} {'p95':>8}")
print("-"*65)

results = []
for cond in ["baseline", "audit", "enforce"]:
    vals = sorted(rows.get(cond, []))
    if not vals:
        print(f"{cond:<12}  no data")
        continue
    mean   = statistics.mean(vals)
    median = statistics.median(vals)
    stdev  = statistics.stdev(vals) if len(vals) > 1 else 0.0
    p95    = vals[min(int(len(vals) * 0.95), len(vals) - 1)]
    print(f"{cond:<12} {len(vals):>4} {mean:>7.0f}ms {median:>7.0f}ms {stdev:>7.0f}ms {p95:>7.0f}ms")
    results.append((cond, len(vals), round(mean), round(median), round(stdev), p95))

b = next((r for r in results if r[0] == "baseline"), None)
e = next((r for r in results if r[0] == "enforce"),  None)
if b and e:
    overhead = e[2] - b[2]
    pct      = overhead / b[2] * 100
    print("-"*65)
    print(f"Kyverno overhead: +{overhead}ms (+{pct:.1f}%)")
print("="*65)

out = f"/tmp/latency-{cloud}.csv"
with open(out, "w") as f:
    f.write("cloud,condition,n,mean_ms,median_ms,stdev_ms,p95_ms\n")
    for r in results:
        f.write(f"{cloud},{r[0]},{r[1]},{r[2]},{r[3]},{r[4]},{r[5]}\n")
print(f"CSV saved: {out}")