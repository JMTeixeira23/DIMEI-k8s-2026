# Phase 1 — Infrastructure & Toolchain Bootstrap (AWS)

> **Thesis project:** Multi-cloud Kubernetes supply chain security using Cosign, Kyverno, and SLSA provenance.  
> **Phase 1 scope:** AWS only (EKS + ECR). Azure (AKS + ACR) follows the same structure and will slot in via `terraform/azure/` and `env.azure` — no changes to scripts or Makefile required.

---

## What this phase delivers

- EKS 1.29 cluster (1 node group, `t3.medium`) and ECR repository provisioned via Terraform
- GitHub Actions CI authenticated to ECR via **OIDC federation** — no stored AWS credentials
- Kyverno installed on EKS (ready for Phase 3 policies)
- Smoke test: image built → pushed to ECR → signed with Cosign keyless → verified → deployed as a pod on EKS

---

## Repository structure

```
phase1/
├── terraform/aws/          # EKS + ECR + OIDC + IAM + Kyverno (Helm)
│   ├── providers.tf
│   ├── variables.tf
│   ├── main.tf
│   └── outputs.tf
├── helm/
│   └── kyverno-values.yaml  # Cloud-agnostic Kyverno config
├── scripts/
│   ├── install-tools.sh     # Installs cosign, syft, crane
│   ├── registry-login.sh    # Docker login (dispatches on $CLOUD)
│   ├── kubeconfig.sh        # kubectl context update (dispatches on $CLOUD)
│   ├── cosign-sign.sh       # Keyless signing wrapper
│   ├── cosign-verify.sh     # Signature verification
│   └── smoke-test.sh        # Deploy ephemeral pod and verify
├── docker/hello-world/
│   ├── Dockerfile           # Multi-stage distroless smoke-test image
│   └── main.go
├── .github/workflows/
│   └── phase1-bootstrap.yml
├── env.aws                  # AWS environment variables (source before make)
├── Makefile
└── README.md
```

---

## Prerequisites

| Tool | Version | Install |
|------|---------|---------|
| Terraform | ≥ 1.6 | https://developer.hashicorp.com/terraform/install |
| AWS CLI | ≥ 2.x | https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html |
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

## Step 1 — Provision AWS infrastructure

```bash
# Authenticate
aws configure
aws sts get-caller-identity   # confirm

# Deploy
cd terraform/aws
terraform init
terraform apply \
  -var="github_org=YOUR_ORG" \
  -var="github_repo=YOUR_REPO"
```

**Terraform creates:**
- VPC with 2 public subnets across 2 AZs
- EKS 1.29 cluster with 1 managed node group (`t3.medium`, min 1 / desired 2 / max 3)
- IAM OIDC provider linked to the EKS cluster's issuer URL
- ECR repository (`supply-chain/hello-world`) with **IMMUTABLE** tags and scan-on-push
- IAM role that GitHub Actions can assume via OIDC (no static credentials)
- Kyverno 3.1.4 installed via Helm

---

## Step 2 — Configure local environment

```bash
# Edit env.aws — fill in AWS_ACCOUNT_ID, GITHUB_ORG, GITHUB_REPO
nano env.aws
source env.aws

# Update kubeconfig
make kubeconfig
kubectl get nodes   # expect 2 Ready nodes
```

---

## Step 3 — Configure GitHub Actions secrets

Add these in **Settings → Secrets and Variables → Actions** (create a `aws` environment):

| Secret | Where to get it |
|--------|----------------|
| `AWS_ROLE_ARN` | `terraform output github_actions_role_arn` |
| `AWS_REGION` | e.g. `eu-west-1` |
| `ECR_REPO_NAME` | e.g. `supply-chain/hello-world` |
| `EKS_CLUSTER_NAME` | e.g. `supply-chain-eks` |

---

## Step 4 — Run the smoke test

### Via GitHub Actions
Push to `main` or trigger manually:
```
Actions → Phase 1 — Bootstrap Smoke Test (AWS) → Run workflow
```

### Locally
```bash
source env.aws
make smoke-test TAG=v0.1.0
```

**What happens:**
1. `docker build` — multi-stage distroless image
2. `docker push` — to ECR (authenticated via `aws ecr get-login-password`)
3. `cosign sign --yes` — keyless: GitHub OIDC → Fulcio certificate → Rekor transparency log
4. `cosign verify` — checks certificate issuer and subject regexp
5. `cosign tree` — shows the signature artefact in the registry
6. `kubectl run` — ephemeral pod, confirms image pulls and exits 0

Expected `cosign tree` output at Phase 1 (Phase 2 adds SBOM + provenance):
```
📦 Supply Chain Security Summary
└── 📦 123456789012.dkr.ecr.eu-west-1.amazonaws.com/supply-chain/hello-world:abc1234
    └── 🔐 Signatures
        └── sha256:def456...
```

---

## Step 5 — Verify Kyverno

```bash
make kyverno-status
```

Expected:
```
NAME                            READY
kyverno-admission-controller    2/2
kyverno-background-controller   1/1
kyverno-reports-controller      1/1
kyverno-cleanup-controller      1/1
```

No ClusterPolicies yet — Phase 3 adds `verify-image-signature`, `verify-slsa-provenance`, and `verify-sbom-cyclonedx`.

---

## Extending to Azure (future)

The project is structured to minimise Azure addition effort:

1. Create `terraform/azure/` with equivalent AKS + ACR + Entra Workload Identity modules
2. Create `env.azure` with the same variable names (`CLOUD`, `IMAGE_REPO`, `REGISTRY`, `OIDC_ISSUER`, etc.)
3. Add `azure)` case blocks to `scripts/registry-login.sh` and `scripts/kubeconfig.sh`
4. Add a `smoke-test-azure` job to the CI workflow
5. The `Makefile`, `cosign-sign.sh`, `cosign-verify.sh`, and `smoke-test.sh` require **zero changes**

The only cloud-specific difference in Phase 3 Kyverno policies will be the registry URL prefix (`*.dkr.ecr.*.amazonaws.com` vs `*.azurecr.io`) and the OIDC subject pattern — the policy structure is identical.

---

## Troubleshooting

**`cosign: command not found`** — run `scripts/install-tools.sh` and add `~/.local/bin` to `$PATH`

**EKS nodes stuck `NotReady`** — check VPC subnets have a route to the internet gateway; nodes need outbound internet to reach ECR

**`cosign verify` fails with certificate error** — ensure `COSIGN_CERTIFICATE_OIDC_ISSUER` in `env.aws` exactly matches the issuer in the Fulcio certificate (`https://token.actions.githubusercontent.com`)

**Kyverno pods in `CrashLoopBackOff`** — usually a resource issue; check `kubectl describe pod -n kyverno` and confirm `t3.medium` nodes are Ready

---

## Phase 1 outputs checklist

- [ ] `terraform/aws/terraform.tfstate` saved
- [ ] `kubeconfig` updated; `kubectl get nodes` shows 2 Ready nodes
- [ ] ECR repository visible in AWS console with at least 1 image
- [ ] `cosign tree` output saved to `docs/phase1-cosign-tree.txt`
- [ ] Both smoke-test pod logs captured
- [ ] Kyverno pods all Running
