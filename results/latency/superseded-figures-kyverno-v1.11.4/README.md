# Superseded figures â€” Kyverno v1.11.4

Plotted from run 30692789440 on the pre-2026-08-15 stack. Every number behind
them was superseded when the cluster was rebuilt on Kyverno v1.18.2 / Cosign
v2.6.5, and the experiment they depict did not control the image verification
cache â€” a variable that changes the in-webhook cost by roughly 150x and did not
exist on v1.11.4.

Regenerate from the current artefacts instead:

    python3 scripts/latency_charts.py \
      results/latency/aws-31892458755-cache-off/latency-requests-aws.csv
