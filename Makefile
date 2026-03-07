# ─────────────────────────────────────────────────────────────────────────────
# Makefile — Phase 1 Bootstrap
#
# Designed to be cloud-agnostic: all targets read from env vars set by
# sourcing env.aws (now) or env.azure (future). Adding Azure support later
# requires only a new env.azure file — no Makefile changes needed.
#
# Usage:
#   source env.aws && make smoke-test
# ─────────────────────────────────────────────────────────────────────────────

SHELL  := /bin/bash
.PHONY: help deps \
        tf-init tf-plan tf-apply tf-destroy tf-output \
        kubeconfig build registry-login \
        push sign verify smoke-test \
        kyverno-status clean

TAG ?= $(shell git rev-parse --short HEAD 2>/dev/null || echo "dev")

# Guard: IMAGE_REPO must be set (done by sourcing env.aws / env.azure)
IMAGE_REPO ?= $(error IMAGE_REPO not set — run: source env.aws)
FULL_IMAGE  = $(IMAGE_REPO):$(TAG)

# ─── Help ────────────────────────────────────────────────────────────────────
help:
	@printf "\n"
	@printf "╔══════════════════════════════════════════════════╗\n"
	@printf "║  Phase 1 — Infrastructure & Toolchain Bootstrap  ║\n"
	@printf "║  Active cloud: %-33s║\n" "$(or $(CLOUD),not set — source env.aws)"
	@printf "╚══════════════════════════════════════════════════╝\n"
	@printf "\n"
	@printf "  deps            Check all required CLI tools are installed\n"
	@printf "\n"
	@printf "  Terraform:\n"
	@printf "    tf-init       terraform init  (terraform/aws)\n"
	@printf "    tf-plan       terraform plan\n"
	@printf "    tf-apply      terraform apply\n"
	@printf "    tf-destroy    terraform destroy\n"
	@printf "    tf-output     Print useful terraform outputs\n"
	@printf "\n"
	@printf "  Cluster:\n"
	@printf "    kubeconfig    Update ~/.kube/config for active cloud\n"
	@printf "    kyverno-status  Check Kyverno pods and policies\n"
	@printf "\n"
	@printf "  Image pipeline (source env.aws first):\n"
	@printf "    build         Build the hello-world image\n"
	@printf "    registry-login  Authenticate Docker to the registry\n"
	@printf "    push          Build + push to registry\n"
	@printf "    sign          Sign image with Cosign keyless\n"
	@printf "    verify        Verify Cosign signature\n"
	@printf "    smoke-test    Full end-to-end: push → sign → verify → deploy\n"
	@printf "\n"
	@printf "    clean         Remove local Docker image\n"
	@printf "\n"

# ─── Deps ────────────────────────────────────────────────────────────────────
deps:
	@echo "🔍 Checking required tools..."
	@for tool in terraform aws kubectl helm cosign syft docker; do \
		command -v $$tool >/dev/null 2>&1 \
			&& echo "  ✅ $$tool" \
			|| echo "  ❌ $$tool — not found"; \
	done
	@echo ""
	@terraform version -json | python3 -c "import sys,json; v=json.load(sys.stdin); print('  terraform', v['terraform_version'])"
	@cosign version 2>&1 | head -1
	@syft version --quiet 2>&1 | head -1

# ─── Terraform ───────────────────────────────────────────────────────────────
TF_DIR = terraform/aws

tf-init:
	cd $(TF_DIR) && terraform init

tf-plan:
	@: $${GITHUB_ORG:?source env.aws first}
	cd $(TF_DIR) && terraform plan \
		-var="github_org=$(GITHUB_ORG)" \
		-var="github_repo=$(GITHUB_REPO)"

tf-apply:
	@: $${GITHUB_ORG:?source env.aws first}
	cd $(TF_DIR) && terraform apply \
		-var="github_org=$(GITHUB_ORG)" \
		-var="github_repo=$(GITHUB_REPO)" \
		-auto-approve

tf-destroy:
	@: $${GITHUB_ORG:?source env.aws first}
	cd $(TF_DIR) && terraform destroy \
		-var="github_org=$(GITHUB_ORG)" \
		-var="github_repo=$(GITHUB_REPO)" \
		-auto-approve

tf-output:
	@cd $(TF_DIR) && echo "=== Useful outputs ===" && terraform output

# ─── Kubeconfig ──────────────────────────────────────────────────────────────
kubeconfig:
	@: $${CLOUD:?source env.aws first}
	@scripts/kubeconfig.sh

# ─── Build ───────────────────────────────────────────────────────────────────
build:
	@echo "🔨 Building $(FULL_IMAGE)..."
	docker build -t "$(FULL_IMAGE)" docker/hello-world
	@echo "✅ Built: $(FULL_IMAGE)"

# ─── Registry login ──────────────────────────────────────────────────────────
registry-login:
	@: $${CLOUD:?source env.aws first}
	@scripts/registry-login.sh

# ─── Push ────────────────────────────────────────────────────────────────────
push: build registry-login
	@echo "📤 Pushing $(FULL_IMAGE)..."
	docker push "$(FULL_IMAGE)"
	@echo "✅ Pushed"

# ─── Sign ────────────────────────────────────────────────────────────────────
sign:
	@: $${COSIGN_CERTIFICATE_OIDC_ISSUER:?source env.aws first}
	@echo "🔏 Signing $(FULL_IMAGE)..."
	@scripts/cosign-sign.sh "$(FULL_IMAGE)"

# ─── Verify ──────────────────────────────────────────────────────────────────
verify:
	@: $${COSIGN_CERTIFICATE_OIDC_ISSUER:?source env.aws first}
	@echo "🔍 Verifying $(FULL_IMAGE)..."
	@scripts/cosign-verify.sh "$(FULL_IMAGE)"

# ─── Smoke Test ──────────────────────────────────────────────────────────────
smoke-test: push sign verify kubeconfig
	@echo "🚀 Running smoke-test pod on $(CLOUD)..."
	@scripts/smoke-test.sh "$(FULL_IMAGE)"

# ─── Kyverno status ──────────────────────────────────────────────────────────
kyverno-status: kubeconfig
	@echo "📋 Kyverno pods:"
	kubectl get pods -n kyverno
	@echo ""
	@echo "📋 ClusterPolicies (added in Phase 3):"
	kubectl get clusterpolicies 2>/dev/null || echo "  (none yet)"

# ─── Clean ───────────────────────────────────────────────────────────────────
clean:
	docker rmi "$(FULL_IMAGE)" 2>/dev/null || true
	@echo "🧹 Local image removed"
