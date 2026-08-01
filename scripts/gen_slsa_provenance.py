#!/usr/bin/env python3
"""
Generates a SLSA v1.0 provenance predicate for the current build.

Called after an image is built and signed, by supply-chain-pipeline.yml and by
the size-image build in measure-admission-latency.yml. Reads build context from
environment variables set by the workflow, writes provenance.json which Cosign
then attests and pushes to the registry.

Environment variables expected:
    GH_REPOSITORY, GH_REF_NAME, GH_SHA, GH_EVENT, GH_WORKFLOW,
    GH_RUN_ID, GH_RUN_ATTEMPT, FULL_IMAGE, BUILD_TIMESTAMP, CLOUD

The builder identity comes from GITHUB_WORKFLOW_REF, which GitHub sets to the
workflow that is actually running. It used to be a hardcoded string naming
`supply-chain.yml` — a file that does not exist in this repository; the pipeline
is `supply-chain-pipeline.yml`. So every provenance attestation ever produced
named a workflow that never ran. Nothing rejected it, because Kyverno verifies
the attestation's signature and type rather than the contents of its predicate,
which is precisely why the error survived: the field was published, trusted in
principle, and checked by nothing.

GITHUB_WORKFLOW_REF is also the value Fulcio puts in the signing certificate's
SAN, so the provenance now names the same identity the Kyverno policy pins.
Set BUILDER_ID explicitly to run this outside GitHub Actions; there is no
fallback, because guessing is how the original defect happened.
"""
import json
import os
import sys

required = [
    "GH_REPOSITORY", "GH_REF_NAME", "GH_SHA", "GH_EVENT",
    "GH_WORKFLOW", "GH_RUN_ID", "GH_RUN_ATTEMPT",
    "FULL_IMAGE", "BUILD_TIMESTAMP", "CLOUD",
]
missing = [k for k in required if not os.environ.get(k)]
if missing:
    print(f"ERROR: missing env vars: {', '.join(missing)}", file=sys.stderr)
    sys.exit(1)

# Identity of the workflow that actually produced this build. GitHub sets
# GITHUB_WORKFLOW_REF to "<owner>/<repo>/.github/workflows/<file>@<ref>".
workflow_ref = os.environ.get("GITHUB_WORKFLOW_REF", "")
builder_id = os.environ.get("BUILDER_ID", "")
if not builder_id:
    if not workflow_ref:
        print("ERROR: neither GITHUB_WORKFLOW_REF nor BUILDER_ID is set. "
              "Refusing to guess the builder identity — a wrong value here is "
              "published in a signed attestation and checked by nothing.",
              file=sys.stderr)
        sys.exit(1)
    builder_id = f"https://github.com/{workflow_ref}"

repo        = os.environ["GH_REPOSITORY"]
ref_name    = os.environ["GH_REF_NAME"]
sha         = os.environ["GH_SHA"]
event       = os.environ["GH_EVENT"]
workflow    = os.environ["GH_WORKFLOW"]
run_id      = os.environ["GH_RUN_ID"]
run_attempt = os.environ["GH_RUN_ATTEMPT"]
full_image  = os.environ["FULL_IMAGE"]
timestamp   = os.environ["BUILD_TIMESTAMP"]
cloud       = os.environ["CLOUD"]

source_uri = f"git+https://github.com/{repo}@refs/heads/{ref_name}"

provenance = {
    "buildDefinition": {
        "buildType": "https://slsa.dev/container-based-build/v0.1",
        "externalParameters": {
            "source": {
                "uri": source_uri,
                "digest": {"gitCommit": sha},
            },
            "image": full_image,
            "cloud": cloud,
        },
        "internalParameters": {
            "githubEventName":  event,
            "githubWorkflow":   workflow,
            "githubRunId":      run_id,
            "githubRunAttempt": run_attempt,
        },
        "resolvedDependencies": [
            {"uri": source_uri, "digest": {"gitCommit": sha}},
        ],
    },
    "runDetails": {
        "builder": {
            "id": builder_id,
        },
        "metadata": {
            "invocationId": (
                f"https://github.com/{repo}/actions/runs/{run_id}"
                f"/attempts/{run_attempt}"
            ),
            "startedOn":  timestamp,
            "finishedOn": timestamp,
        },
    },
}

with open("provenance.json", "w") as f:
    json.dump(provenance, f, indent=2)

print("Provenance written to provenance.json")
print(f"  builder : {provenance['runDetails']['builder']['id']}")
print(f"  cloud   : {cloud}")
print(f"  commit  : {sha}")