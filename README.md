# Multi-Cloud Kubernetes Supply Chain Security

> **Thesis:** Multi-cloud Kubernetes supply chain security using Cosign, Kyverno, and SLSA provenance.
> **Clouds:** AWS EKS + Azure AKS — one pipeline, one set of policies, parallel enforcement.

---

## What this project does

Every commit to `docker/` triggers a fully automated supply chain on both clouds simultaneously:

```
git push
  ├── AWS EKS:   build → sign → SBOM → provenance → verify → deploy → enforce policies
  └── Azure AKS: build → sign → SBOM → provenance → verify → deploy → enforce policies
```

Three Kyverno policies written once enforce identical security requirements on both clusters. A pod is only admitted if its image has a valid Cosign signature, a CycloneDX SBOM attestation, and a SLSA v1.0 provenance attestation — all from the correct GitHub Actions identity.

---

## Repository layout

```
.github/workflows/
  supply-chain-pipeline.yml         — CD pipeline (auto on docker/ push, matrix: aws + azure)
  measure-admission-latency.yml     — Latency, image-size and concurrency measurement (manual)
  attack-simulations.yml            — Attack scenarios A1–A6 + TC-NS (manual, thesis evidence)
  evasion-tests.yml                 — Evasion suite E1–E4: attacks aimed at the policies' own
                                      assumptions, where some are expected to SUCCEED

docker/
  hello-world/                      — The workload under test (Alpine 3.19 base)
  small/ medium/ large/ xlarge/     — Phase 4b size experiment images (5–400MB)

policies/
  verify-image-signature.yaml       — Requires valid Cosign keyless signature
  verify-sbom-cyclonedx.yaml        — Requires signed CycloneDX SBOM attestation
  verify-slsa-provenance.yaml       — Requires signed SLSA v1.0 provenance attestation
  values/
    aws.env                         — REGISTRY=812982728774.dkr.ecr.eu-west-1.amazonaws.com
    azure.env                       — REGISTRY=supplychainthesis.azurecr.io

scripts/
  gen_slsa_provenance.py            — Generates the SLSA provenance predicate signed inside the build
  slsa-l2-evidence.sh               — Records the SLSA Build L2 evidence, keeping what was observed
                                      separate from the level claimed from it

  admission-lib.sh                  — Admission probe + evidence recording, shared by the suites below
  admission-summary.sh              — Builds an evidence artefact (JSON + CSV) from the recorded results
  attack-lib.sh                     — Scenario manifest for attack-simulations.yml
  attack-summary.sh                 — Attack artefact entry point (attack-results-<cloud>.json)
  testcase-lib.sh                   — TC-01…TC-05 manifest for supply-chain-pipeline.yml
  testcase-summary.sh               — Test-case artefact entry point (testcase-results-<cloud>.json)
  evasion-lib.sh                    — E1–E4 manifest; which cases exist depends on the dispatched ref
  evasion-summary.sh                — Evasion artefact entry point (evasion-results-<cloud>.json)

  run-latency-matrix.sh             — Runs baseline/audit/enforce in a seeded, recorded order
  measure-admission.sh              — Measures one condition (used by measure-admission-latency.yml)
  measure-concurrency.sh            — Concurrency sweep at several parallelism levels
  kyverno_metrics.py                — Scrapes and deltas Kyverno's Prometheus histograms
  latency_report.py                 — Builds the latency artefact from a measurement run
  latency_analysis.py               — Mann-Whitney U, effect size and percentiles from requests.csv
  latency_charts.py                 — ECDF + violin figures for both experiments (run locally)

  set-failure-policy.sh             — Switches the cluster fail-open/fail-closed and verifies it took
  set-verify-cache.sh               — Switches Kyverno's image verification cache on/off and verifies
                                      it took; the cache changes in-webhook cost by ~150x, so it is a
                                      recorded condition of every performance run, not a default
  policy-ready.sh                   — One reader for ClusterPolicy readiness across Kyverno versions
  webhook-state.sh                  — Prints the admission configuration an evidence run executed under
  node-state.sh                     — Prints the worker hardware an evidence run executed on; the two
                                      clouds run different instance families, so it is a condition of
                                      every latency number rather than background detail
  version-audit.sh                  — Pinned versions vs upstream, and why each pin is where it is
  diagnose-image-verification.sh    — Read-only: why did Kyverno deny an image Cosign verified?

  attack_table.py                   — Renders the security tables from their artefacts
  latency_table.py                  — Renders the performance tables from their artefacts
  render-all-tables.sh              — Regenerates every table into results/TABLES-<cloud>.{tex,md};
                                      pass `both` for one table set with a column per cloud, which
                                      is the form the dissertation uses
  results-manifest.py               — Rebuilds results/MANIFEST.md: every artefact, its run, its stack
  local/
    install-tools.sh                — Installs cosign, syft, crane locally
    registry-login.sh               — Docker login for local use (dispatches on $CLOUD)
    kubeconfig.sh                   — kubectl context update for local use
    cosign-sign.sh                  — Local signing wrapper
    cosign-verify.sh                — Local verification wrapper
    smoke-test.sh                   — Local smoke test
    env.aws                         — Local environment variables (source before make)

docs/
  literature/                       — Literature queries (CSV exports)

infrastructure/
  aws/                              — EKS + ECR + OIDC + IAM
  azure/                            — AKS + ACR + Entra Workload Identity

results/
  MANIFEST.md                       — Generated: every artefact, its run, and the stack it ran on
  TABLES-aws.tex / .md              — Generated: every dissertation table, with provenance
  <experiment>/<cloud>-<run>[-arm]/ — One directory per run; superseded runs are kept, not deleted

bootstrap-aws.sh                    — Post-apply setup for AWS (Kyverno + policies + namespaces)
bootstrap-azure.sh                  — Post-apply setup for Azure
versions.env                        — Single source of truth for every third-party version, and the
                                      separate record of which versions results/ was collected on
Makefile                            — Local dev shortcuts
```

### What was added for the evaluation, in one line each

- **Evasion suite (E1–E4)** — attacks aimed at the *policies' own assumptions*
  rather than at obviously bad images. Two of the four are expected to succeed;
  the artefact carries a `control` field so "4/4 as predicted" can never be
  misread as "4/4 blocked".
- **SLSA Build L2** — provenance generated and signed by the hosted build
  platform, alongside the L1 provenance generated inside the build. Additive and
  revertible: set the repository variable `SLSA_L2=false` and nothing else
  changes. The pipeline *produces* L2; admission still *enforces* on L1.
- **Verification cache as a condition** — Kyverno v1.18.2 caches image
  verification for one hour. It changes in-webhook cost by roughly 150×, so
  every performance experiment is run twice, cold and warm, and each artefact
  records which it was.
- **Fail-open / fail-closed** — the security suites run under both admission
  failure configurations; the webhook name in each denial proves which was
  active, independently of what the switch reported.
- **Everything is rendered, nothing is typed** — every table in the dissertation
  comes from `render-all-tables.sh` reading committed artefacts, and each table
  carries the run id, URL, Kyverno version and cache state it came from.

---

## Prerequisites

| Tool | Version |
|------|---------|
| Terraform | ≥ 1.6 |
| AWS CLI | ≥ 2.x |
| Azure CLI | ≥ 2.x |
| kubectl | ≥ 1.29 |
| Helm | ≥ 3.14 |
| cosign | 2.2.3 |
| syft | ≥ 0.105 |
| Docker | ≥ 24 |

```bash
bash scripts/local/install-tools.sh   # installs cosign, syft, crane
make deps                        # checks all tools are present
```

---

## Provisioning

### AWS

```bash
cd infrastructure/aws
terraform init
terraform apply \
  -var="github_org=JMTeixeira23" \
  -var="github_repo=DIMEI-k8s-2026" \
  -auto-approve

cd ../..
bash bootstrap-aws.sh
```

Bootstrap: configures kubeconfig, imports and updates the Kyverno IAM role trust policy (OIDC provider ID changes on each rebuild), installs Kyverno v1.11.4 (Helm chart 3.1.4), patches webhook failure policies, applies the three ClusterPolicies, labels namespaces.

### Azure

```bash
cd infrastructure/azure
terraform init
terraform apply \
  -var="github_org=JMTeixeira23" \
  -var="github_repo=DIMEI-k8s-2026" \
  -var="location=swedencentral" \
  -auto-approve

cd ../..
bash bootstrap-azure.sh
```

Bootstrap prints the exact secret values to set in GitHub at the end.

---

## GitHub environments and secrets

Two environments: `aws` and `azure` (Settings → Environments).

### `aws`

| Secret | Value |
|--------|-------|
| `AWS_ROLE_ARN` | `terraform output github_actions_role_arn` |
| `AWS_REGION` | `eu-west-1` |
| `ECR_REPO_NAME` | `supply-chain/hello-world` |
| `EKS_CLUSTER_NAME` | `supply-chain-eks` |

### `azure`

| Secret | Value |
|--------|-------|
| `AZURE_CLIENT_ID` | printed by bootstrap-azure.sh |
| `AZURE_TENANT_ID` | printed by bootstrap-azure.sh |
| `AZURE_SUBSCRIPTION_ID` | printed by bootstrap-azure.sh |
| `ACR_LOGIN_SERVER` | printed by bootstrap-azure.sh |
| `ACR_REPO_NAME` | `supply-chain/hello-world` |
| `AKS_CLUSTER_NAME` | `supply-chain-aks` |
| `AKS_RESOURCE_GROUP` | `supply-chain-rg` |

The Azure secrets change on every `terraform destroy` + `terraform apply` because Entra app registrations are recreated with new client IDs. Always read from bootstrap output after rebuilding.

---

## CD pipeline

Triggered automatically on any `docker/**` change. Can also be run manually.

```
Supply Chain (aws)                    Supply Chain (azure)
  Build → push to ECR                   Build → push to ACR
  Sign  → Cosign keyless (Rekor)        Sign  → Cosign keyless (Rekor)
  SBOM  → CycloneDX via Syft            SBOM  → CycloneDX via Syft
  Prov  → SLSA v1.0                     Prov  → SLSA v1.0
  Verify → cosign verify + tree         Verify → cosign verify + tree
  Smoke test on EKS                     Smoke test on AKS
  Apply policies (Enforce)              Apply policies (Enforce)
  Preflight: record enforcement state   Preflight: record enforcement state
  TC-01 … TC-05 admission tests         TC-01 … TC-05 admission tests
  Upload testcase-results-aws.json      Upload testcase-results-azure.json
```

The only cloud-specific steps are auth, registry login, and kubeconfig. All signing, attestation, verification, and policy enforcement steps are identical.

The five admission tests are declared in `scripts/testcase-lib.sh` and, like the
attack simulations, **report what they observed rather than what they intended**:

| Case | Scenario | Requirement | Expected |
|------|----------|-------------|----------|
| TC-01 | This run's image: signed, SBOM- and provenance-attested, deployed by digest | SR-01, SR-03, SR-04 | **Admitted** — the positive control |
| TC-02 | `nginx:latest` from docker.io | SR-05 | Denied by `block-unapproved-registry` |
| TC-03 | `alpine:latest` from docker.io | SR-05 | Denied by `block-unapproved-registry` |
| TC-04 | Unsigned image pushed to the approved registry, deployed by digest | SR-01, SR-06 | Denied by `check-image-signature` |
| TC-05 | TC-04's exact image in the `default` namespace | SR-07 | **Admitted** — policies are scoped to `supply-chain-demo` |

TC-01 exists so that a cluster which denied everything could not score four out
of five. TC-05 re-uses TC-04's published digest, so the only variable between
them is the namespace. Each run uploads `testcase-results-<cloud>.json`, and the
job fails unless every case matched its expected outcome:

```bash
python3 scripts/attack_table.py --preset testcases testcase-results-aws.json
```

---

## Kyverno policies

Three ClusterPolicies, written once, applied to both clusters. The registry URL (`REGISTRY_PLACEHOLDER`) is substituted by `sed` at apply time using `policies/values/<cloud>.env`.

```yaml
# verify-image-signature.yaml — blocks wrong-registry images, requires Cosign signature
# verify-sbom-cyclonedx.yaml  — requires CycloneDX SBOM (supply-chain-demo ns only)
# verify-slsa-provenance.yaml — requires SLSA provenance (supply-chain-demo ns only)
```

Adding a new cloud means creating one `policies/values/<cloud>.env` file with the registry URL. No policy files change.

---

## Manual workflows

### Latency measurement

```
Actions → Measure Admission Latency → Run workflow
  cloud: both / aws / azure
  iterations: 30
  size_iterations: 20
```

Measures admission latency across three conditions (baseline/audit/enforce) and
across four image sizes. Probes are **unschedulable pods created in
`supply-chain-demo`**, so what is measured is admission alone: no image pull, no
scheduling, and the policies actually match. Conditions run in a randomised
order seeded from the run id, recorded in the artefact so a run repeats exactly.

**Results are not published here.** Each run uploads `latency-<cloud>.json`,
`size-latency-<cloud>.json`, their CSVs and the raw per-request `requests.csv`.
Committed evidence lives under `results/latency/<cloud>-<run-id>/`. Recompute
any figure from the raw requests:

```bash
python3 scripts/latency_analysis.py requests.csv --all-pairs
```

Two facts about the measurement that are easy to get wrong:

- **A pod creation costs two admission reviews**, not one — it passes through
  both the mutating and the validating webhook. Kyverno's histogram is per
  review, so per-pod cost is twice the per-review mean. `latency_report.py`
  derives `per_request_ms` for this reason.
- **Kyverno v1.11.4 has no image verification cache**, recorded in each artefact
  as `image_verify_cache_flag`. Every admission pays the full Rekor round trip;
  there is no warm/cold distinction to measure on this version.

### Generating charts

Both figures are drawn from `requests.csv` — the per-request file — rather than
from the summary CSVs, because percentiles and distribution shape cannot be
recovered from a summary:

```bash
pip install matplotlib numpy
python3 scripts/latency_charts.py \
  --requests results/latency/aws-30692789440/latency-requests-aws.csv \
  --preset policy --out results/latency/admission-latency-policy

python3 scripts/latency_charts.py \
  --requests results/latency/aws-30692789440/size-requests-aws.csv \
  --preset size --out results/latency/admission-latency-size
```

Each writes a `.png` and a `.pdf`; the PDF is the one to `\includegraphics`. The
statistics printed on the figure are computed by `latency_analysis.py`, not
typed, so a figure cannot disagree with the tables.

### Attack simulations

```
Actions → Attack Simulations → Run workflow
  cloud: both / aws / azure
  probe_namespace_mechanism: false   (diagnostic only — see below)
```

Six attack classes and one namespace-scoping control. The expected admission
outcome and the rule expected to produce it are declared in the scenario
manifest at the top of `scripts/attack-lib.sh`; the probe and recording
machinery is shared with the pipeline's test cases via `scripts/admission-lib.sh`,
so both suites use one definition of what a pass is:

| Class | Scenario | Requirement | Expected |
|-------|----------|-------------|----------|
| A1 | Unsigned image from an unapproved external registry (`alpine:latest`) | SR-05 | Denied by `block-unapproved-registry` |
| A2 | Valid Cosign signature from an attacker-held key | SR-01 | Denied by `check-image-signature` |
| A3 | Tag redirected to unsigned content after signing, deployed by tag | SR-02 | Denied by `check-image-signature` |
| A4 | Signed and provenance-attested, SBOM omitted | SR-03 | Denied by `check-sbom-cyclonedx` |
| A5 | Signed and SBOM-attested, provenance omitted | SR-04 | Denied by `check-slsa-provenance` |
| A6 | Unsigned image in the approved registry | SR-01, SR-06 | Denied by `check-image-signature` |
| TC-NS | The A6 image in the `default` namespace | SR-07 | **Admitted** — policies are scoped to `supply-chain-demo` |

**Results are not published here.** Each run uploads
`attack-results-<cloud>.json` and `.csv`, built from what each scenario observed
at admission — including scenarios that failed or did not run. That artefact is
the only source for the results table:

```bash
# Download both artefacts from the workflow run, then:
python3 scripts/attack_table.py attack-results-aws.json attack-results-azure.json
python3 scripts/attack_table.py --format markdown attack-results-*.json
```

The workflow fails if any scenario deviates from its expected outcome, and the
job summary table is rendered from the same records. Nothing about the outcome
of a run is written by hand anywhere in this repository.

`probe_namespace_mechanism: true` additionally determines whether the
`kyverno.io/exclude` label on the `default` namespace is load-bearing for TC-NS
or whether the policies' `match` scope alone is doing the work. It temporarily
removes and restores that label, so leave it off for evidence runs.

---

## Destroy and rebuild

The full stack is reproducible from code. To verify:

```bash
# Destroy
cd infrastructure/aws   && terraform destroy -var="github_org=JMTeixeira23" -var="github_repo=DIMEI-k8s-2026" -auto-approve
cd ../azure        && terraform destroy -var="github_org=JMTeixeira23" -var="github_repo=DIMEI-k8s-2026" -var="location=swedencentral" -auto-approve

# Rebuild
cd infrastructure/aws   && terraform apply -var="github_org=JMTeixeira23" -var="github_repo=DIMEI-k8s-2026" -auto-approve
cd ../azure        && terraform apply -var="github_org=JMTeixeira23" -var="github_repo=DIMEI-k8s-2026" -var="location=swedencentral" -auto-approve

cd ~/DIMEI/DIMEI-k8s-2026
bash bootstrap-aws.sh
bash bootstrap-azure.sh
# Update azure GitHub secrets from bootstrap-azure.sh output
# Trigger: Supply Chain Security Pipeline → cloud: both
```

Note: after rebuilding AWS, `bootstrap-aws.sh` automatically imports the Kyverno IAM role into Terraform state and runs `terraform apply -target` to update the OIDC trust policy. This is necessary because the EKS OIDC provider ID changes on each rebuild.

---

## Troubleshooting

**`cosign: command not found`** — run `scripts/local/install-tools.sh`

**EKS nodes `NotReady`** — check VPC subnets have a route to the internet gateway

**Kyverno webhook `context deadline exceeded`** — run `bash bootstrap-aws.sh` again; it applies `forceFailurePolicyIgnore` so Kyverno registers its webhooks as `failurePolicy=Ignore`, and labels the default namespace. Note that the effective webhook timeout is Kyverno's default of **10 s** — the chart exposes no value for it

**Azure `AADSTS700016`** — Entra app IDs changed after rebuild; update GitHub secrets from `terraform output` or from bootstrap-azure.sh output

**TC-01 blocked with `missing digest`** — policies have `verifyDigest: false` so this should not happen; check that the pipeline step that applies policies ran successfully before the test cases

**Kyverno `401 Unauthorized` on ECR** — IRSA trust policy has the wrong OIDC provider ID; run `bash bootstrap-aws.sh` which fixes this automatically