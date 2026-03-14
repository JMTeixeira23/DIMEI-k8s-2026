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
  supply-chain.yml        — CD pipeline (auto on docker/ push, matrix: aws + azure)
  measure-latency.yml     — Latency measurement (manual, thesis data collection)
  attack-simulations.yml  — Attack scenarios (manual, thesis evidence)

docker/
  hello-world/            — The workload under test (distroless image)
  small/ medium/ large/ xlarge/  — Phase 4b size experiment images (5–400MB)

kyverno/
  verify-image-signature.yaml   — Requires valid Cosign keyless signature
  verify-sbom-cyclonedx.yaml    — Requires signed CycloneDX SBOM attestation
  verify-slsa-provenance.yaml   — Requires signed SLSA v1.0 provenance attestation
  values/
    aws.env               — REGISTRY=812982728774.dkr.ecr.eu-west-1.amazonaws.com
    azure.env             — REGISTRY=supplychainthesis.azurecr.io

scripts/
  gen_provenance.py       — Generates SLSA provenance predicate (used by pipeline)
  latency_stats.py        — Computes latency statistics (used by measure-latency.yml)
  size_latency_stats.py   — Computes size/latency statistics (used by measure-latency.yml)
  install-tools.sh        — Installs cosign, syft, crane locally
  registry-login.sh       — Docker login for local use (dispatches on $CLOUD)
  kubeconfig.sh           — kubectl context update for local use
  cosign-sign.sh          — Local signing wrapper
  cosign-verify.sh        — Local verification wrapper
  smoke-test.sh           — Local smoke test

docs/
  generate_charts.py      — Generates Phase 4 latency bar chart (run locally)
  generate_size_charts.py — Generates Phase 4b size/latency line chart (run locally)
  figures/                — Chart output directory (created on first run)

terraform/
  aws/                    — EKS + ECR + OIDC + IAM
  azure/                  — AKS + ACR + Entra Workload Identity

bootstrap.sh              — Post-apply setup for AWS (Kyverno + policies + namespaces)
bootstrap-azure.sh        — Post-apply setup for Azure
env.aws                   — Local environment variables (source before make)
Makefile                  — Local dev shortcuts
```

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
bash scripts/install-tools.sh   # installs cosign, syft, crane
make deps                        # checks all tools are present
```

---

## Provisioning

### AWS

```bash
cd terraform/aws
terraform init
terraform apply \
  -var="github_org=JMTeixeira23" \
  -var="github_repo=DIMEI-k8s-2026" \
  -auto-approve

cd ../..
bash bootstrap.sh
```

Bootstrap: configures kubeconfig, imports and updates the Kyverno IAM role trust policy (OIDC provider ID changes on each rebuild), installs Kyverno 3.1.4, patches webhook failure policies, applies the three ClusterPolicies, labels namespaces.

### Azure

```bash
cd terraform/azure
terraform apply \
  -var="github_org=JMTeixeira23" \
  -var="github_repo=DIMEI-k8s-2026" \
  -var="location=northeurope" \
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
  TC-01: signed image admitted          TC-01: signed image admitted
  TC-02: nginx blocked                  TC-02: nginx blocked
  TC-03: alpine blocked                 TC-03: alpine blocked
```

The only cloud-specific steps are auth, registry login, and kubeconfig. All signing, attestation, verification, and policy enforcement steps are identical.

---

## Kyverno policies

Three ClusterPolicies, written once, applied to both clusters. The registry URL (`REGISTRY_PLACEHOLDER`) is substituted by `sed` at apply time using `kyverno/values/<cloud>.env`.

```yaml
# verify-image-signature.yaml — blocks wrong-registry images, requires Cosign signature
# verify-sbom-cyclonedx.yaml  — requires CycloneDX SBOM (supply-chain-demo ns only)
# verify-slsa-provenance.yaml — requires SLSA provenance (supply-chain-demo ns only)
```

Adding a new cloud means creating one `kyverno/values/<cloud>.env` file with the registry URL. No policy files change.

---

## Manual workflows

### Latency measurement

```
Actions → Measure Admission Latency → Run workflow
  cloud: both / aws / azure
  iterations: 30
  size_iterations: 20
```

Measures admission latency across three conditions (baseline/audit/enforce) and across four image sizes (5/30/120/400MB). Downloads two CSV artifacts per cloud.

**Phase 4 results:**

| Cloud | Baseline | Enforce | Overhead |
|-------|----------|---------|---------|
| AWS EKS | 31,834ms | 31,879ms | +45ms (+0.1%) |
| Azure AKS | 3,744ms | 3,713ms | -31ms (-0.8%) |

Overhead is within one standard deviation — statistically indistinguishable from zero.

**Phase 4b results (O(1) hypothesis):**

| Cloud | Small (5MB) | XLarge (400MB) | Spread |
|-------|------------|----------------|--------|
| AWS EKS | 4,241ms | 4,466ms | 225ms |
| Azure AKS | 3,602ms | 4,061ms | 459ms |

Spread is within the measurement noise (σ ≈ 800ms AWS, σ ≈ 500ms Azure). O(1) confirmed — Kyverno verifies the digest against Rekor without pulling image layers.

### Generating charts

After downloading the CSV artifacts from a latency run:

```bash
pip install matplotlib numpy

# Phase 4 — admission overhead bar chart
python3 docs/generate_charts.py latency-aws.csv latency-azure.csv
# → docs/figures/admission_latency_overhead.png

# Phase 4b — image size line chart
python3 docs/generate_size_charts.py size-latency-aws.csv size-latency-azure.csv
# → docs/figures/size_vs_latency.png
```

### Attack simulations

```
Actions → Attack Simulations → Run workflow
  cloud: both / aws / azure
```

| Attack | Threat | Blocking policy |
|--------|--------|----------------|
| A1 | Unsigned image | verify-image-signature |
| A2 | Wrong OIDC signer (local key) | verify-image-signature |
| A3 | Digest tampering (TOCTOU) | verify-image-signature |
| A4 | Missing SBOM | verify-sbom-cyclonedx |
| A5 | Missing SLSA provenance | verify-slsa-provenance |

Result: **5/5 blocked on AWS and Azure**.

---

## Destroy and rebuild

The full stack is reproducible from code. To verify:

```bash
# Destroy
cd terraform/aws   && terraform destroy -var="github_org=JMTeixeira23" -var="github_repo=DIMEI-k8s-2026" -auto-approve
cd ../azure        && terraform destroy -var="github_org=JMTeixeira23" -var="github_repo=DIMEI-k8s-2026" -var="location=northeurope" -auto-approve

# Rebuild
cd terraform/aws   && terraform apply -var="github_org=JMTeixeira23" -var="github_repo=DIMEI-k8s-2026" -auto-approve
cd ../azure        && terraform apply -var="github_org=JMTeixeira23" -var="github_repo=DIMEI-k8s-2026" -var="location=northeurope" -auto-approve

cd ~/DIMEI/DIMEI-k8s-2026
bash bootstrap.sh
bash bootstrap-azure.sh
# Update azure GitHub secrets from bootstrap-azure.sh output
# Trigger: Supply Chain Security Pipeline → cloud: both
```

Note: after rebuilding AWS, `bootstrap.sh` automatically imports the Kyverno IAM role into Terraform state and runs `terraform apply -target` to update the OIDC trust policy. This is necessary because the EKS OIDC provider ID changes on each rebuild.

---

## Troubleshooting

**`cosign: command not found`** — run `scripts/install-tools.sh`

**EKS nodes `NotReady`** — check VPC subnets have a route to the internet gateway

**Kyverno webhook `context deadline exceeded`** — run `bash bootstrap.sh` again; it patches all webhooks to `failurePolicy=Ignore` and labels the default namespace to exclude it from interception

**Azure `AADSTS700016`** — Entra app IDs changed after rebuild; update GitHub secrets from `terraform output` or from bootstrap-azure.sh output

**TC-01 blocked with `missing digest`** — policies have `verifyDigest: false` so this should not happen; check that the pipeline step that applies policies ran successfully before the test cases

**Kyverno `401 Unauthorized` on ECR** — IRSA trust policy has the wrong OIDC provider ID; run `bash bootstrap.sh` which fixes this automatically