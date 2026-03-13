# Multi-Cloud Kubernetes Supply Chain Security

> **Thesis project:** Multi-cloud Kubernetes supply chain security using Cosign, Kyverno, and SLSA provenance.
> **Clouds:** AWS EKS + Azure AKS — unified pipeline, identical policies, parallel enforcement.

---

## What this project delivers

A **cloud-agnostic supply chain security framework** for Kubernetes with three layers:

| Layer | What it is | Cloud-specific? |
|-------|-----------|----------------|
| **Policies** | 3 Kyverno ClusterPolicies — signature, SBOM, provenance | No — written once, registry URL injected at apply time |
| **Pipeline** | One GitHub Actions workflow — matrix across clouds | No — only auth + registry login differ per cloud |
| **Infrastructure** | Terraform for EKS + ECR (AWS) and AKS + ACR (Azure) | Yes — intentionally separate |

Every `docker/` push triggers the full supply chain on **both clouds in parallel**:
build → sign → SBOM → provenance → verify → smoke test → enforce policies → TC-01/02/03.

---

## Repository structure

```
.github/workflows/
  supply-chain.yml        ← ONE unified CD pipeline (matrix: aws, azure)
  measure-latency.yml     ← Manual: admission latency measurement (aws, azure, or both)
  attack-simulations.yml  ← Manual: 5 attack scenarios (aws, azure, or both)

docker/
  hello-world/            ← Distroless smoke-test image (the workload under test)

kyverno/
  verify-image-signature.yaml   ← Written ONCE — cloud-agnostic
  verify-sbom-cyclonedx.yaml    ← Written ONCE — cloud-agnostic
  verify-slsa-provenance.yaml   ← Written ONCE — cloud-agnostic
  values/
    aws.env               ← REGISTRY=812982728774.dkr.ecr.eu-west-1.amazonaws.com
    azure.env             ← REGISTRY=supplychainthesis.azurecr.io

terraform/
  aws/                    ← EKS + ECR + OIDC + IAM + Kyverno IRSA
  azure/                  ← AKS + ACR + Entra Workload Identity

helm/
  kyverno-values.yaml     ← Cloud-agnostic Kyverno Helm values

scripts/
  install-tools.sh        ← Installs cosign, syft, crane
  registry-login.sh       ← Docker login (dispatches on $CLOUD)
  kubeconfig.sh           ← kubectl context update (dispatches on $CLOUD)
  cosign-sign.sh          ← Keyless signing wrapper
  cosign-verify.sh        ← Signature verification
  smoke-test.sh           ← Deploy ephemeral pod and verify

docs/
  generate_charts.py      ← Regenerate Phase 4 latency charts (thesis figures)
  generate_size_charts.py ← Regenerate Phase 4b size vs latency charts

bootstrap.sh              ← Run once after terraform apply (AWS) — installs Kyverno + policies
bootstrap-azure.sh        ← Run once after terraform apply (Azure) — installs Kyverno + policies
env.aws                   ← AWS environment variables (source before make)
Makefile                  ← Local dev shortcuts
```

---

## Prerequisites

| Tool | Version | Install |
|------|---------|---------|
| Terraform | ≥ 1.6 | https://developer.hashicorp.com/terraform/install |
| AWS CLI | ≥ 2.x | https://docs.aws.amazon.com/cli/latest/userguide/ |
| Azure CLI | ≥ 2.x | https://docs.microsoft.com/cli/azure/install-azure-cli |
| kubectl | ≥ 1.29 | https://kubernetes.io/docs/tasks/tools/ |
| Helm | ≥ 3.14 | https://helm.sh/docs/intro/install/ |
| cosign | 2.2.3 | `scripts/install-tools.sh` |
| syft | ≥ 0.105 | `scripts/install-tools.sh` |
| Docker | ≥ 24 | https://docs.docker.com/engine/install/ |

```bash
scripts/install-tools.sh   # installs cosign, syft, crane to ~/.local/bin
make deps                  # verifies all tools are present
```

---

## Provisioning infrastructure

### AWS

```bash
cd terraform/aws
terraform init
terraform apply \
  -var="github_org=JMTeixeira23" \
  -var="github_repo=DIMEI-k8s-2026" \
  -auto-approve

cd ../..
bash bootstrap.sh          # installs Kyverno + applies policies + creates namespaces
```

**Terraform creates:** VPC (2 AZ), EKS 1.34, ECR, GitHub Actions OIDC role, Kyverno IRSA role.

### Azure

```bash
cd terraform/azure
terraform init
terraform apply \
  -var="github_org=JMTeixeira23" \
  -var="github_repo=DIMEI-k8s-2026" \
  -var="location=northeurope" \
  -auto-approve

cd ../..
bash bootstrap-azure.sh    # installs Kyverno + applies policies + creates namespaces
```

**Terraform creates:** Resource group, AKS 1.29, ACR, Entra app registrations + federated credentials, RBAC assignments.

---

## GitHub Actions environments and secrets

Create two environments in **Settings → Environments**: `aws` and `azure`.

### `aws` environment secrets

| Secret | Value |
|--------|-------|
| `AWS_ROLE_ARN` | `terraform output github_actions_role_arn` |
| `AWS_REGION` | `eu-west-1` |
| `ECR_REPO_NAME` | `supply-chain/hello-world` |
| `EKS_CLUSTER_NAME` | `supply-chain-eks` |

### `azure` environment secrets

| Secret | Value |
|--------|-------|
| `AZURE_CLIENT_ID` | `terraform output github_actions_client_id` |
| `AZURE_TENANT_ID` | `terraform output tenant_id` |
| `AZURE_SUBSCRIPTION_ID` | `terraform output subscription_id` |
| `ACR_LOGIN_SERVER` | `terraform output acr_login_server` |
| `ACR_REPO_NAME` | `supply-chain/hello-world` |
| `AKS_CLUSTER_NAME` | `supply-chain-aks` |
| `AKS_RESOURCE_GROUP` | `supply-chain-rg` |

---

## CD pipeline — supply-chain.yml

**Trigger:** any commit that changes `docker/**` → full pipeline runs on AWS and Azure in parallel.
**Manual trigger:** `workflow_dispatch` with `cloud` input (aws / azure / both).

```
docker/ change pushed
    │
    ├── supply-chain (aws)
    │     Build → Sign → SBOM → Provenance → Verify → Smoke test
    │     → Apply Kyverno policies (Enforce) → TC-01/02/03
    │
    └── supply-chain (azure)
          Build → Sign → SBOM → Provenance → Verify → Smoke test
          → Apply Kyverno policies (Enforce) → TC-01/02/03
```

**What the pipeline proves per cloud:**

| Step | Thesis evidence |
|------|----------------|
| Cosign keyless sign | Signature bound to GitHub OIDC identity via Fulcio + Rekor |
| Syft CycloneDX SBOM | Full software bill of materials attested |
| SLSA v1.0 provenance | Build origin cryptographically provable |
| Kyverno Enforce | Admission blocked without all three attestations |
| TC-01 admitted | Fully attested image passes all 3 policies |
| TC-02/03 blocked | Non-registry images blocked at admission |

The only cloud-specific steps in the entire pipeline are:
1. OIDC auth (AWS role assumption vs Azure login)
2. Registry login (ECR vs ACR)
3. Kubeconfig (eks update-kubeconfig vs aks get-credentials)
4. Registry URL injected from `kyverno/values/<cloud>.env`

---

## Kyverno policies

Three ClusterPolicies written once and applied to every cluster:

```
kyverno/verify-image-signature.yaml   — blocks non-registry images + requires Cosign signature
kyverno/verify-sbom-cyclonedx.yaml    — requires signed CycloneDX SBOM attestation
kyverno/verify-slsa-provenance.yaml   — requires signed SLSA v1.0 provenance attestation
```

The registry URL (`REGISTRY_PLACEHOLDER`) is injected by `sed` at apply time:

```bash
# Conceptually what the pipeline does:
REGISTRY=$(grep REGISTRY kyverno/values/aws.env | cut -d= -f2)
sed "s|REGISTRY_PLACEHOLDER|${REGISTRY}|g" kyverno/verify-image-signature.yaml \
  | kubectl apply --server-side -f -
```

To add a new cloud, create `kyverno/values/<cloud>.env` with the registry URL — no policy files change.

---

## Manual workflows

### Admission latency measurement

```
Actions → Measure Admission Latency → Run workflow
  cloud: both / aws / azure
  iterations: 30
```

Measures Kyverno admission overhead across three conditions (baseline / audit / enforce), uploads a CSV artifact per cloud. Results from this thesis:

| Cloud | Baseline | Enforce | Overhead |
|-------|----------|---------|---------|
| AWS EKS | 1195ms | 1228ms | +33ms (+2.8%) |
| Azure AKS | (run to collect) | | |

### Attack simulations

```
Actions → Attack Simulations → Run workflow
  cloud: both / aws / azure
```

Five attacks run on each selected cloud. All expected to be blocked:

| Attack | Threat | Policy that fires |
|--------|--------|------------------|
| A1 | Unsigned image | `verify-image-signature` |
| A2 | Wrong OIDC signer (local key) | `verify-image-signature` |
| A3 | Digest tampering (TOCTOU) | `verify-image-signature` |
| A4 | Missing SBOM | `verify-sbom-cyclonedx` |
| A5 | Missing SLSA provenance | `verify-slsa-provenance` |

AWS result: **5/5 attacks blocked**.

---

## Destroy and rebuild

The full stack is reproducible from code. To verify:

```bash
# Destroy
cd terraform/aws   && terraform destroy -var="github_org=JMTeixeira23" -var="github_repo=DIMEI-k8s-2026" -auto-approve
cd ../azure        && terraform destroy -var="github_org=JMTeixeira23" -var="github_repo=DIMEI-k8s-2026" -var="location=northeurope" -auto-approve

# Rebuild
cd terraform/aws   && terraform apply  -var="github_org=JMTeixeira23" -var="github_repo=DIMEI-k8s-2026" -auto-approve
cd ../azure        && terraform apply  -var="github_org=JMTeixeira23" -var="github_repo=DIMEI-k8s-2026" -var="location=northeurope" -auto-approve

# Bootstrap
cd ~/DIMEI/DIMEI-k8s-2026
bash bootstrap.sh
bash bootstrap-azure.sh

# Verify — trigger supply-chain pipeline on both clouds
```

---

## Troubleshooting

**`cosign: command not found`** — run `scripts/install-tools.sh` and add `~/.local/bin` to `$PATH`

**EKS nodes `NotReady`** — check VPC subnets have a route to the internet gateway

**Kyverno `401 Unauthorized` on ECR** — IRSA annotation missing; re-run `bootstrap.sh`

**Azure login `AADSTS700016`** — `AZURE_CLIENT_ID` or `AZURE_TENANT_ID` secret is wrong; check `terraform output`

**Federated credential subject mismatch** — ensure the Entra federated credential subject is `repo:ORG/REPO:environment:azure` (not `ref:...`) because the workflow uses an environment

**TC-01 blocked unexpectedly** — ECR query picked up an `attack*` or `size-*` tag; these are excluded by the jq filter in the pipeline

**Kyverno hook timeout on install** — run `helm uninstall kyverno -n kyverno`, delete the namespace, wait 15s, re-run `bootstrap.sh`