#!/usr/bin/env python3
"""
Renders an admission-results table directly from the evidence artefacts the
workflows upload. Two tables in the dissertation come from here:

    Table 6.3  attack simulations   .github/workflows/attack-simulations.yml
    Table 6.2  pipeline test cases  .github/workflows/supply-chain-pipeline.yml

Both suites emit the same record schema, so one renderer serves both — the
alternative was a second copy of this file that would drift from the first.

The point of the script is that no result in the dissertation is ever typed by
hand: download the artefacts from the workflow run and render. If a case did not
run, it appears in the table as such rather than silently vanishing.

Usage:
    python3 scripts/attack_table.py attack-results-aws.json attack-results-azure.json
    python3 scripts/attack_table.py --format markdown attack-results-*.json
    python3 scripts/attack_table.py --preset testcases testcase-results-aws.json
    python3 scripts/attack_table.py --preset evasion   evasion-results-aws.json
    python3 scripts/attack_table.py fail-open.json fail-closed.json   # 1.3

The evasion preset (revision item 2.2) adds a Control column, because a matched
prediction in that suite does not mean the attempt was blocked — two of its
cases are predicted to get through, and the column is what keeps the table from
being read as another clean sweep.

Columns are one per artefact, labelled by cluster. When two artefacts come from
the same cluster — the fail-open / fail-closed comparison revision item 1.3
asks for — the label gains the admission configuration each run recorded, so
the two columns cannot be confused for each other or silently overwrite one
another.

Options:
    --format latex|markdown   output format (default: latex)
    --preset attacks|testcases  caption, label and row noun (default: attacks)
    --label <str>             LaTeX label, overriding the preset
    --caption <str>           caption text, overriding the preset
"""
import argparse
import json
import sys

PRESETS = {
    "attacks": {
        "label":   "tab:attacks",
        "caption": "Attack simulation outcomes on {where}. Every row is "
                   "rendered from the evidence artefact uploaded by the attack "
                   "simulation workflow run cited above.",
        "noun":    "scenarios",
        "column":  "Scenario",
        "idcol":   "Class",
    },
    "testcases": {
        "label":   "tab:testcases",
        "caption": "Pipeline admission test outcomes on {where}. Every row is "
                   "rendered from the evidence artefact uploaded by the supply "
                   "chain pipeline run cited above.",
        "noun":    "test cases",
        "column":  "Test case",
        "idcol":   "ID",
    },
    # The evasion suite is the one table where a matched prediction is not
    # necessarily good news, so it gets an extra column saying which it is.
    # Without it the table reads like the attack table and would be quoted as
    # "n/n blocked", which is the opposite of what two of the rows show.
    "evasion": {
        "label":   "tab:evasion",
        "caption": "Evasion attempt outcomes on {where}. The Control column "
                   "states whether the predicted outcome represents the "
                   "control holding or being evaded --- two of these attempts "
                   "are expected to succeed. Every row is rendered from the "
                   "evidence artefact uploaded by the evasion test run cited "
                   "above.",
        "noun":    "evasion attempts",
        "column":  "Evasion attempt",
        "idcol":   "Case",
        "control": True,
        "matched": "behaved as predicted",
    },
}

OBSERVED_LABEL = {
    "DENY":    "Denied",
    "ADMIT":   "Admitted",
    "ERROR":   "Error",
    "NOT_RUN": "Not run",
    # Evasion suite: E2's verdict is not an admission outcome. The pod is
    # admitted either way; what is recorded is whether the content running
    # inside it was substituted afterwards.
    "EVADED":  "Substituted",
    "BLOCKED": "Not substituted",
}

CONTROL_LABEL = {
    "holds":  "Holds",
    "evaded": "Evaded",
}


def load(paths):
    runs = []
    for path in paths:
        with open(path) as fh:
            doc = json.load(fh)
        if "scenarios" not in doc or "run" not in doc:
            sys.exit(f"{path}: not an admission-results artefact")
        runs.append(doc)
    if not runs:
        sys.exit("no artefacts given")

    label_runs(runs)

    order = [s["scenario"] for s in runs[0]["scenarios"]]
    for doc in runs[1:]:
        if [s["scenario"] for s in doc["scenarios"]] != order:
            sys.exit(
                "artefacts cover different case sets — they come from "
                "different versions of the workflow, or from different suites, "
                "and must not be combined into one table"
            )
    return runs, order


CLUSTER_NAMES = {"aws": "AWS EKS", "azure": "Azure AKS"}


def label_runs(runs):
    """Give every artefact a column label, disambiguated only when it has to be.

    Keyed on cloud alone, a fail-open and a fail-closed run of the same cluster
    collapse into one column and the second silently replaces the first. That is
    exactly the comparison item 1.3 asks for, so the label falls back to the
    admission configuration each run recorded — read from the cluster at
    preflight, not from the workflow input — and then to the run id if even that
    does not separate them.
    """
    for doc in runs:
        run = doc["run"]
        cloud = run.get("cloud", "?")
        run["_label"] = CLUSTER_NAMES.get(cloud, cloud.upper())
        run["_config"] = (run.get("admission") or {}).get("configuration")

    seen = {}
    for doc in runs:
        seen.setdefault(doc["run"]["_label"], []).append(doc)

    for label, group in seen.items():
        if len(group) == 1:
            continue
        configs = [d["run"].get("_config") for d in group]
        if len(set(configs)) == len(configs) and all(configs):
            for doc in group:
                doc["run"]["_label"] = f"{label} ({doc['run']['_config']})"
        else:
            for doc in group:
                doc["run"]["_label"] = f"{label} (run {doc['run'].get('run_id', '?')})"

    keys = [d["run"]["_label"] for d in runs]
    if len(set(keys)) != len(keys):
        sys.exit("two artefacts could not be told apart: " + ", ".join(keys))


def cell(scenario, latex):
    """Observed outcome for one scenario, emphasised when it was not expected."""
    text = OBSERVED_LABEL.get(scenario["observed_admission"], scenario["observed_admission"])
    if scenario["outcome"] == "PASS":
        return text
    return f"\\textbf{{{text}}}" if latex else f"**{text}**"


def escape(text):
    return text.replace("&", "\\&").replace("_", "\\_").replace("%", "\\%")


def control_cell(scenario):
    """What a matched prediction means for the control, for the evasion preset.

    Absent on records the shared renderer synthesised for cases that never ran,
    so a missing value is reported rather than assumed to be either one.
    """
    raw = scenario.get("control")
    if not raw:
        return "---"
    return CONTROL_LABEL.get(raw, raw)


def totals(doc):
    """Counts recomputed from the rows being rendered.

    The artefact carries its own totals block; recomputing here means the
    sentence under the table can never disagree with the rows above it. A
    mismatch means the artefact was edited after the run, and says so.
    """
    rows = doc["scenarios"]
    counted = {
        "total": len(rows),
        "pass": sum(1 for s in rows if s["outcome"] == "PASS"),
        "fail": sum(1 for s in rows if s["outcome"] == "FAIL"),
        "error": sum(1 for s in rows if s["outcome"] == "ERROR"),
    }
    recorded = doc.get("totals")
    if recorded and recorded != counted:
        print(
            f"warning: {doc['run']['cloud']} artefact totals {recorded} disagree with "
            f"its own scenario rows {counted} — the artefact has been modified since "
            f"the run; using the rows",
            file=sys.stderr,
        )
    return counted


def render_latex(runs, order, preset):
    labels = [doc["run"]["_label"] for doc in runs]
    by_label = {doc["run"]["_label"]: {s["scenario"]: s for s in doc["scenarios"]}
                for doc in runs}
    first = {s["scenario"]: s for s in runs[0]["scenarios"]}

    out = []
    out.append("% Generated by scripts/attack_table.py — do not edit by hand.")
    out.append("% Source artefacts:")
    for doc in runs:
        r = doc["run"]
        out.append(
            f"%   {r['_label']}: run {r['run_id']} ({r.get('run_url', 'n/a')}), "
            f"generated {r['generated']}, kyverno {r.get('kyverno_image', 'unknown')}"
            + (f", admission {r['_config']}" if r.get("_config") else "")
        )
    where = " and ".join(dict.fromkeys(labels))
    out.append("\\begin{table}[htbp]")
    out.append("  \\centering")
    out.append("  \\caption{" + preset["caption"].format(where=where) + "}")
    out.append(f"  \\label{{{preset['label']}}}")
    control = preset.get("control", False)
    extra = 1 if control else 0
    cols = " ".join(["p{1.4cm}"] + ["X"] + ["p{1.8cm}"] * (1 + 1 + extra + len(labels)))
    out.append(f"  \\begin{{tabularx}}{{\\textwidth}}{{{cols}}}")
    out.append("    \\toprule")
    header = [f"\\textbf{{{preset['idcol']}}}", f"\\textbf{{{preset['column']}}}",
              "\\textbf{Requirements}", "\\textbf{Expected}"]
    if control:
        header.append("\\textbf{Control}")
    header += [f"\\textbf{{{escape(l)}}}" for l in labels]
    out.append("    " + " & ".join(header) + " \\\\")
    out.append("    \\midrule")

    for sid in order:
        meta = first[sid]
        row = [
            escape(sid),
            escape(meta["title"]),
            escape(", ".join(meta["requirements"])),
            OBSERVED_LABEL.get(meta["expected_admission"], meta["expected_admission"]),
        ]
        if control:
            row.append(control_cell(meta))
        row += [cell(by_label[l][sid], latex=True) for l in labels]
        out.append("    " + " & ".join(row) + " \\\\")

    out.append("    \\bottomrule")
    out.append("  \\end{tabularx}")
    out.append("\\end{table}")

    matched = preset.get("matched", "matched the expected admission outcome")
    for doc in runs:
        t = totals(doc)
        out.append(
            f"% {doc['run']['_label']}: {t['pass']}/{t['total']} {preset['noun']} {matched} "
            f"({t['fail']} unexpected, {t['error']} not run or errored)"
        )
    return "\n".join(out)


def render_markdown(runs, order, preset):
    labels = [doc["run"]["_label"] for doc in runs]
    by_label = {doc["run"]["_label"]: {s["scenario"]: s for s in doc["scenarios"]}
                for doc in runs}
    first = {s["scenario"]: s for s in runs[0]["scenarios"]}

    control = preset.get("control", False)
    head = [preset["idcol"], preset["column"], "Requirements", "Expected"]
    if control:
        head.append("Control")
    out = ["| " + " | ".join(head + labels) + " |"]
    out.append("|" + "---|" * (len(head) + len(labels)))
    for sid in order:
        meta = first[sid]
        row = [sid, meta["title"], ", ".join(meta["requirements"]),
               OBSERVED_LABEL.get(meta["expected_admission"], meta["expected_admission"])]
        if control:
            row.append(control_cell(meta))
        row += [cell(by_label[l][sid], latex=False) for l in labels]
        out.append("| " + " | ".join(row) + " |")
    out.append("")
    # The markdown footer has always been terser than the LaTeX one; the default
    # keeps it that way so the existing presets render byte-identically.
    matched = preset.get("matched", "as expected")
    for doc in runs:
        r, t = doc["run"], totals(doc)
        out.append(
            f"{r['_label']}: {t['pass']}/{t['total']} {matched} "
            f"({t['fail']} unexpected, {t['error']} not run or errored) — run {r['run_id']}"
        )
    return "\n".join(out)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("artefacts", nargs="+")
    ap.add_argument("--format", choices=["latex", "markdown"], default="latex")
    ap.add_argument("--preset", choices=sorted(PRESETS), default="attacks")
    ap.add_argument("--label")
    ap.add_argument("--caption")
    args = ap.parse_args()

    preset = dict(PRESETS[args.preset])
    if args.label:
        preset["label"] = args.label
    if args.caption:
        preset["caption"] = args.caption

    runs, order = load(args.artefacts)
    # Sorted by cloud, then by configuration, so fail-open precedes fail-closed
    # and the columns read in the order the discussion presents them.
    runs.sort(key=lambda d: (d["run"].get("cloud", ""),
                             d["run"].get("_label", "")))
    if args.format == "latex":
        print(render_latex(runs, order, preset))
    else:
        print(render_markdown(runs, order, preset))


if __name__ == "__main__":
    main()
