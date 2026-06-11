#!/usr/bin/env python3
"""
Generates a SLSA v1.0 provenance predicate for the current build.

Called by the supply-chain pipeline after the image is built and signed.
Reads build context from environment variables set by the workflow, writes
provenance.json which Cosign then attests and pushes to the registry.

Environment variables expected:
    GH_REPOSITORY, GH_REF_NAME, GH_SHA, GH_EVENT, GH_WORKFLOW,
    GH_RUN_ID, GH_RUN_ATTEMPT, FULL_IMAGE, BUILD_TIMESTAMP, CLOUD
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
            "id": f"https://github.com/{repo}/.github/workflows/supply-chain.yml"
                  f"@refs/heads/{ref_name}",
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

print(f"Provenance written to provenance.json")
print(f"  builder : {provenance['runDetails']['builder']['id']}")
print(f"  cloud   : {cloud}")
print(f"  commit  : {sha}")