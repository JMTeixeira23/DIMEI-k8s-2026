#!/usr/bin/env python3
"""
Builds results/MANIFEST.md: one row per evidence artefact under results/, read
from the artefacts themselves.

Answers, without opening any of them: what was measured, on which run, against
which Kyverno, under which admission configuration, and whether it is the
current evidence or superseded by a later run.

The "current vs superseded" column is derived, not declared: an artefact is
superseded when another artefact of the same experiment has a higher run id.
Superseded artefacts are kept deliberately — they are the evidence behind the
dissertation text as it stands today — so the repository needs to say which is
which rather than relying on directory names to imply it.

Usage:
    python3 scripts/results-manifest.py            # writes results/MANIFEST.md
    python3 scripts/results-manifest.py --stdout   # prints instead
"""
import argparse
import json
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
RESULTS = ROOT / "results"

# Which artefact filenames belong to which experiment, and how to read a
# headline result out of each. Adding an experiment means adding a row here,
# not editing the walker.
KINDS = {
    "testcase-results":   "pipeline admission tests",
    "attack-results":     "attack simulations",
    "evasion-results":    "evasion suite",
    "latency":            "admission latency matrix",
    "size-latency":       "image size vs cost",
    "concurrency":        "concurrency sweep",
    "slsa-l2":            "SLSA Build L2 provenance",
}


def classify(path):
    name = path.name
    # Longest match first: 'size-latency-aws.json' must not classify as 'latency'.
    for key in sorted(KINDS, key=len, reverse=True):
        if name.startswith(key):
            return KINDS[key]
    return None


def read(path):
    try:
        with path.open() as fh:
            return json.load(fh)
    except Exception as exc:                      # noqa: BLE001 - reported, not raised
        return {"_error": str(exc)}


def facts(doc):
    """Pull the common descriptors out of whichever schema this artefact uses.

    Three schemas are in play — the suites nest under `run`, the performance
    experiments under `environment`, and the SLSA evidence under `run` with a
    different body — so each field is looked for in every plausible place rather
    than assuming one shape.
    """
    # Not every file under results/ is a record object: some are bare arrays
    # (per-level throughput, image size lists). They are evidence too, but they
    # carry no environment block, so they are described rather than parsed.
    if isinstance(doc, list):
        return {"run": "?", "when": "?", "kyverno": "--", "cfg": "--",
                "cache": "--", "result": f"{len(doc)} entries (array)"}
    if not isinstance(doc, dict):
        return {"run": "?", "when": "?", "kyverno": "--", "cfg": "--",
                "cache": "--", "result": f"{type(doc).__name__} literal"}
    if "_error" in doc:
        return {"run": "?", "when": "?", "kyverno": "unreadable", "cfg": "?",
                "cache": "?", "result": doc["_error"][:60]}
    env = doc.get("environment") or doc.get("run") or {}
    if not isinstance(env, dict):
        env = {}
    adm = env.get("admission") or {}
    totals = doc.get("totals") or {}

    if totals:
        result = f"{totals.get('pass', '?')}/{totals.get('total', '?')}"
    elif doc.get("claim", {}).get("level"):
        result = doc["claim"]["level"]
    elif doc.get("conditions"):
        result = f"{len(doc['conditions'])} conditions"
    else:
        result = "--"

    cache = env.get("image_verify_cache_enabled")
    cache = {True: "off→on", "true": "on", False: "off", "false": "off"}.get(
        cache, cache or "--")

    return {
        "run": str(env.get("run_id") or (env.get("run_url", "").rstrip("/").split("/")[-1]) or "?"),
        "when": (env.get("generated") or "?")[:10],
        "kyverno": (env.get("kyverno_image") or "unknown").split(":")[-1],
        "cfg": adm.get("configuration", "--"),
        "cache": cache,
        "result": result,
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--stdout", action="store_true")
    args = ap.parse_args()

    if not RESULTS.is_dir():
        sys.exit("error: results/ not found")

    rows = []
    for path in sorted(RESULTS.rglob("*.json")):
        kind = classify(path)
        if kind is None:
            continue
        f = facts(read(path))
        f["kind"] = kind
        f["path"] = path.relative_to(ROOT).as_posix()
        f["superseded_dir"] = "superseded" in f["path"]
        rows.append(f)

    # ── Current vs superseded is decided by the STACK, not by run recency ────
    #
    # The first version of this script took the highest run id per experiment.
    # That is wrong whenever an experiment legitimately has more than one
    # current artefact — and most of them do: fail-open and fail-closed,
    # cache-off and cache-on, evasion on main and on a branch. Those are arms of
    # one comparison, not successive attempts, and marking the lower run id
    # "superseded" would discard half of every paired result.
    #
    # What actually supersedes an artefact here is the cluster rebuild: every
    # result collected on Kyverno v1.11.4 was invalidated when the stack moved
    # to v1.18.2. So the test is the Kyverno version the artefact recorded,
    # against the version versions.env currently pins.
    #
    # Artefacts that did not record their Kyverno version are reported as
    # `undetermined` rather than assumed either way. That is not a cosmetic
    # gap: it is the visible consequence of a recording defect, and it should
    # stay visible until those experiments are re-run.
    pin = "unknown"
    versions = ROOT / "versions.env"
    if versions.is_file():
        for line in versions.read_text().splitlines():
            if line.startswith("KYVERNO_APP_VERSION="):
                pin = line.split("=", 1)[1].strip().strip('"').lstrip("v")
                break

    for r in rows:
        recorded = (r["kyverno"] or "").lstrip("v")
        if r["superseded_dir"]:
            r["state"] = "superseded"
        elif r["kind"] == KINDS["slsa-l2"]:
            # Build-side evidence: it describes what the pipeline produced, not
            # what a cluster did, so no Kyverno version applies and its absence
            # is correct rather than a gap.
            r["state"] = "current"
            r["kyverno"] = "n/a (build-side)"
        elif recorded in ("", "unknown", "--"):
            r["state"] = "undetermined"
        elif recorded == pin:
            r["state"] = "current"
        else:
            r["state"] = "superseded"

    out = []
    out.append("# Evidence manifest")
    out.append("")
    out.append("Generated by `scripts/results-manifest.py` — do not edit by hand.")
    out.append("")
    out.append("Every row is read from the artefact itself. **State** is derived "
               "from the Kyverno version each artefact recorded, against the "
               f"version `versions.env` pins (`{pin}`) — not from run recency, "
               "because most experiments have two current artefacts that are "
               "arms of one comparison (fail-open/fail-closed, cache-off/"
               "cache-on, evasion on main/on a branch).")
    out.append("")
    out.append("Superseded artefacts are kept on purpose: they are the evidence "
               "behind the dissertation text as currently written. "
               "`undetermined` means the artefact did not record its Kyverno "
               "version — a recording gap, not a judgement.")
    out.append("")
    out.append("| Experiment | State | Run | Date | Kyverno | Admission | Cache | Result | Artefact |")
    out.append("|---|---|---|---|---|---|---|---|---|")
    rank = {"current": 0, "undetermined": 1, "superseded": 2}
    for r in sorted(rows, key=lambda x: (x["kind"], rank.get(x["state"], 9), x["run"])):
        mark = {"current": "**current**", "undetermined": "_undetermined_"}.get(
            r["state"], "superseded")
        out.append(f"| {r['kind']} | {mark} | `{r['run']}` | {r['when']} | "
                   f"{r['kyverno']} | {r['cfg']} | {r['cache']} | {r['result']} | "
                   f"`{r['path']}` |")
    out.append("")
    cur = sum(1 for r in rows if r["state"] == "current")
    und = sum(1 for r in rows if r["state"] == "undetermined")
    line = f"{len(rows)} artefacts, {cur} current"
    if und:
        line += f", {und} undetermined (did not record a Kyverno version)"
    out.append(line + ".")
    text = "\n".join(out) + "\n"

    if args.stdout:
        print(text, end="")
    else:
        (RESULTS / "MANIFEST.md").write_text(text, encoding="utf-8", newline="\n")
        print(f"Wrote results/MANIFEST.md — {len(rows)} artefacts, {cur} current.")


if __name__ == "__main__":
    main()
