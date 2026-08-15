#!/usr/bin/env python3
"""
Renders the performance tables directly from the evidence artefacts, the way
scripts/attack_table.py does for the security tables.

Three tables in the dissertation come from here:

    admission overhead   latency-aws.json         (policy matrix)
    image size vs cost   size-latency-aws.json    (Phase 4b)
    concurrency          concurrency-aws.json     (revision item 1.4)

Each is rendered from two artefacts — one with Kyverno's image verification
cache enabled and one without — because on Kyverno v1.18.2 that single flag
changes the in-webhook cost by roughly two orders of magnitude, and either
number quoted alone is misleading. The column headings are derived from each
artefact's own `image_verify_cache_enabled` field, so a table cannot claim a
cache state its source did not record.

Nothing here is typed by hand: every cell traces to a committed artefact, and
the provenance comment above each table names the run, the URL, the Kyverno
image and the cache state it came from.

Usage:
    python3 scripts/latency_table.py --preset overhead \\
        results/latency/aws-*-cache-off/latency-aws.json \\
        results/latency/aws-*-cache-on/latency-aws.json

    python3 scripts/latency_table.py --preset size \\
        results/latency/aws-*-size-cache-off/size-latency-aws.json \\
        results/latency/aws-*-size-cache-on/size-latency-aws.json

    python3 scripts/latency_table.py --preset concurrency \\
        results/concurrency/aws-*-cache-off/concurrency-aws.json \\
        results/concurrency/aws-*-cache-on/concurrency-aws.json

Options:
    --format latex|markdown   output format (default: latex)
    --label <str>             LaTeX label, overriding the preset
    --caption <str>           caption text, overriding the preset
"""
import argparse
import glob
import json
import sys

PRESETS = {
    "overhead": {
        "label": "tab:admission-overhead",
        "caption": "Admission latency by policy configuration and image "
                   "verification cache state. Client cost is the wall-clock "
                   "time of the pod creation request; in-webhook cost is "
                   "Kyverno's own admission-review histogram read as "
                   "$\\Delta$sum$/\\Delta$count over the batch.",
        "idcol": "Condition",
    },
    "size": {
        "label": "tab:size-cost",
        "caption": "Admission cost against image size, with the image "
                   "verification cache disabled and enabled. Sizes are "
                   "measured from the built images, not nominal.",
        "idcol": "Image",
    },
    "concurrency": {
        "label": "tab:concurrency",
        "caption": "Admission cost and rejections under concurrent pod "
                   "creation, with the image verification cache disabled and "
                   "enabled, against a 10-second webhook timeout.",
        "idcol": "Concurrency",
    },
}


def escape(s):
    """LaTeX-escape a cell. Kept deliberately small: these are identifiers and
    numbers, not prose."""
    if s is None:
        return "--"
    s = str(s)
    for a, b in (("\\", r"\textbackslash{}"), ("&", r"\&"), ("%", r"\%"),
                 ("_", r"\_"), ("#", r"\#"), ("$", r"\$")):
        s = s.replace(a, b)
    return s


def num(v, digits=1):
    """Format a number, or an em dash when the measurement does not exist.

    A missing value is never rendered as 0 or as a blank: `request_cost` is null
    when every request in a condition was rejected, and `in_webhook_cost` is
    null when no admission review matched the namespace filter. Both are real
    states that a reader must be able to tell apart from a measured zero.
    """
    if v is None:
        return "--"
    try:
        return f"{float(v):.{digits}f}"
    except (TypeError, ValueError):
        return escape(v)


def cache_state(doc):
    """The cache state this artefact recorded, as a column label.

    Read from the artefact rather than inferred from the filename, so a
    mislabelled directory cannot produce a mislabelled table.

    `_supplied_state` is set only by --cache-state, for artefacts collected
    before the workflow recorded the field. It is deliberately a separate key so
    that `provenance()` can mark those columns as asserted rather than measured
    — the distinction between "the artefact says so" and "the operator says so"
    is exactly the kind that must not be quietly lost.
    """
    if doc.get("_supplied_state"):
        return doc["_supplied_state"]
    env = doc.get("environment", doc)
    raw = env.get("image_verify_cache_enabled")
    if raw in (True, "true"):
        return "cache on (warm)"
    if raw in (False, "false"):
        return "cache off (cold)"
    return "cache state unrecorded"


CLOUD_NAMES = {"aws": "AWS EKS", "azure": "Azure AKS"}


def cloud_of(doc):
    """The cloud this artefact was collected on, as a column label."""
    env = doc.get("environment", doc)
    raw = doc.get("cloud") or env.get("cloud") or "?"
    return CLOUD_NAMES.get(str(raw).lower(), str(raw))


def col_label(doc, multi_cloud):
    """Column prefix: cache state alone, or cloud + cache state.

    A two-cloud table has two artefacts per cache state, so labelling by cache
    state alone produces two identically-named columns and the reader cannot
    tell which cloud a number belongs to. The cloud is added only when the
    artefacts actually span more than one, so single-cloud tables keep their
    existing, shorter headers.
    """
    return f"{cloud_of(doc)}, {cache_state(doc)}" if multi_cloud else cache_state(doc)


def spans_clouds(docs):
    return len({cloud_of(d) for d in docs}) > 1


def provenance(docs, paths):
    out = ["% Generated by scripts/latency_table.py — do not edit by hand.",
           "% Source artefacts:"]
    for doc, path in zip(docs, paths):
        env = doc.get("environment", doc)
        asserted = " [state ASSERTED via --cache-state, not read from the " \
                   "artefact]" if doc.get("_supplied_state") else ""
        out.append(
            f"%   {cloud_of(doc)}, {cache_state(doc)}: {path}{asserted}"
        )
        out.append(
            f"%     run {env.get('run_url', 'n/a')}, generated "
            f"{env.get('generated', '?')}, kyverno "
            f"{env.get('kyverno_image', 'unknown')}, replicas "
            f"{env.get('kyverno_ready_replicas', '?')}, admission "
            f"{(env.get('admission') or {}).get('configuration', '?')}"
        )
        ex = env.get("execution") or {}
        if ex.get("condition_order"):
            out.append(f"%     condition order {ex['condition_order']} "
                       f"({ex.get('order_source', 'unspecified')})")
    return out


# ── row builders, one per preset ─────────────────────────────────────────────

def rows_overhead(docs):
    _multi = spans_clouds(docs)
    order, seen = [], set()
    for d in docs:
        for c in d["conditions"]:
            if c["condition"] not in seen:
                seen.add(c["condition"])
                order.append(c["condition"])
    header = ["Condition"]
    for d in docs:
        header += [f"{col_label(d, _multi)}: client p50 (ms)",
                   f"{col_label(d, _multi)}: in-webhook (ms)"]
    rows = []
    for cond in order:
        row = [cond]
        for d in docs:
            c = next((x for x in d["conditions"] if x["condition"] == cond), None)
            rc = (c or {}).get("request_cost") or {}
            wh = (c or {}).get("in_webhook_cost") or {}
            row += [num(rc.get("p50_ms"), 0), num(wh.get("per_request_ms"), 1)]
        rows.append(row)
    return header, rows


def rows_size(docs):
    _multi = spans_clouds(docs)
    # Image metadata is identical across arms; take it from whichever artefact
    # records it, preferring the first that does.
    images = {}
    for d in docs:
        for i in (d.get("environment", {}).get("images") or []):
            images.setdefault(i["name"], i)

    order, seen = [], set()
    for d in docs:
        for c in d["conditions"]:
            n = c["condition"].replace("size-", "")
            if n not in seen:
                seen.add(n)
                order.append(n)

    header = ["Image", "Size (MB)", "Layers"]
    for d in docs:
        header += [f"{col_label(d, _multi)}: in-webhook (ms)",
                   f"{col_label(d, _multi)}: admitted"]
    rows = []
    for name in order:
        img = images.get(name, {})
        mb = img.get("compressed_bytes")
        row = [name,
               num(mb / 1e6, 1) if mb else "--",
               str(img.get("layer_count", "--"))]
        for d in docs:
            c = next((x for x in d["conditions"]
                      if x["condition"].replace("size-", "") == name), None)
            wh = (c or {}).get("in_webhook_cost") or {}
            sent = (c or {}).get("requests_sent")
            rej = (c or {}).get("rejected_requests")
            if sent is None or rej is None:
                admitted = "--"
            else:
                admitted = f"{sent - rej}/{sent}"
            row += [num(wh.get("per_request_ms"), 1), admitted]
        rows.append(row)
    return header, rows


def rows_concurrency(docs):
    _multi = spans_clouds(docs)
    def level(cond):
        digits = "".join(ch for ch in cond if ch.isdigit())
        return int(digits) if digits else 0

    order, seen = [], set()
    for d in docs:
        for c in d["conditions"]:
            lv = level(c["condition"])
            if lv not in seen:
                seen.add(lv)
                order.append(lv)
    order.sort()

    header = ["Concurrency"]
    for d in docs:
        header += [f"{col_label(d, _multi)}: in-webhook (ms)",
                   f"{col_label(d, _multi)}: rejected"]
    rows = []
    for lv in order:
        row = [str(lv)]
        for d in docs:
            c = next((x for x in d["conditions"] if level(x["condition"]) == lv), None)
            wh = (c or {}).get("in_webhook_cost") or {}
            sent = (c or {}).get("requests_sent")
            rej = (c or {}).get("rejected_requests")
            row += [num(wh.get("per_request_ms"), 1),
                    "--" if rej is None else f"{rej}/{sent}"]
        rows.append(row)
    return header, rows


BUILDERS = {"overhead": rows_overhead, "size": rows_size,
            "concurrency": rows_concurrency}


def render_latex(header, rows, preset, prov):
    out = list(prov)
    out.append("\\begin{table}[htbp]")
    out.append("  \\centering")
    out.append("  \\small")
    out.append("  \\caption{" + preset["caption"] + "}")
    out.append(f"  \\label{{{preset['label']}}}")
    cols = "l" + "r" * (len(header) - 1)
    out.append(f"  \\begin{{tabular}}{{{cols}}}")
    out.append("    \\toprule")
    out.append("    " + " & ".join(f"\\textbf{{{escape(h)}}}" for h in header) + " \\\\")
    out.append("    \\midrule")
    for r in rows:
        out.append("    " + " & ".join(escape(c) for c in r) + " \\\\")
    out.append("    \\bottomrule")
    out.append("  \\end{tabular}")
    out.append("\\end{table}")
    return "\n".join(out)


def render_markdown(header, rows, preset, prov):
    out = [l.lstrip("% ") for l in prov]
    out.append("")
    out.append("| " + " | ".join(header) + " |")
    out.append("|" + "|".join("---" for _ in header) + "|")
    for r in rows:
        out.append("| " + " | ".join(str(c) for c in r) + " |")
    return "\n".join(out)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("artefacts", nargs="+")
    ap.add_argument("--preset", choices=sorted(PRESETS), required=True)
    ap.add_argument("--format", choices=["latex", "markdown"], default="latex")
    ap.add_argument("--label")
    ap.add_argument("--caption")
    ap.add_argument(
        "--cache-state", action="append", default=[],
        metavar="LABEL",
        help="Column label for artefacts collected before the workflow recorded "
             "image_verify_cache_enabled. Given once per artefact, in order. "
             "Marked in the provenance comment as asserted, not measured — use "
             "only where the state is documented elsewhere. Pass 'auto' for any "
             "artefact that records the field itself; required when one table "
             "mixes older and newer artefacts, since the count must match.")
    args = ap.parse_args()

    # Expand globs ourselves: the documented invocations use wildcards, and a
    # shell that does not expand them (or a path that matches nothing) would
    # otherwise reach json.load as a literal '*' and fail obscurely.
    paths = []
    for a in args.artefacts:
        hits = sorted(glob.glob(a))
        if not hits:
            sys.exit(f"error: no artefact matched {a!r}")
        paths.extend(hits)

    docs = []
    for p in paths:
        with open(p) as fh:
            docs.append(json.load(fh))

    for d, p in zip(docs, paths):
        if "conditions" not in d:
            sys.exit(f"error: {p} has no 'conditions' — is it the right artefact?")

    if args.cache_state:
        if len(args.cache_state) != len(docs):
            sys.exit(f"error: --cache-state given {len(args.cache_state)} time(s) "
                     f"for {len(docs)} artefact(s); give it once per artefact, "
                     f"in the same order")
        for d, label in zip(docs, args.cache_state):
            # 'auto' means "this artefact records its own state, leave it alone".
            # Needed because the count must equal the artefact count while
            # supplying a label for a recording artefact is refused — without a
            # sentinel, a table mixing pre- and post-recording artefacts is
            # unrenderable. The two-cloud size and concurrency tables are exactly
            # that: the AWS arms predate the field, the Azure ones carry it.
            if label in ("auto", "-"):
                continue
            env = d.get("environment", d)
            if env.get("image_verify_cache_enabled") not in (None, "", "unknown"):
                sys.exit("error: refusing to override a cache state the artefact "
                         "records. Pass 'auto' for that artefact instead of a "
                         "label, or drop --cache-state entirely.")
            d["_supplied_state"] = label

    # Compared as (cloud, state) pairs: in a two-cloud table each state legitimately
    # appears twice, once per cloud, and warning about that would train the reader
    # to ignore the message. A genuine duplicate is the same cloud twice in the
    # same state, which means the comparison was not actually performed.
    states = [(cloud_of(d), cache_state(d)) for d in docs]
    if len(set(states)) != len(states):
        dupes = sorted({s for s in states if states.count(s) > 1})
        print(f"warning: the same cloud and cache state appears more than once "
              f"({dupes}). The comparison this table is for may not have been "
              "performed.", file=sys.stderr)

    preset = dict(PRESETS[args.preset])
    if args.label:
        preset["label"] = args.label
    if args.caption:
        preset["caption"] = args.caption

    header, rows = BUILDERS[args.preset](docs)
    prov = provenance(docs, paths)
    render = render_latex if args.format == "latex" else render_markdown
    print(render(header, rows, preset, prov))


if __name__ == "__main__":
    main()
