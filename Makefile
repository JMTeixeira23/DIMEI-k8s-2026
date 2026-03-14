# Makefile — local development shortcuts for the supply chain security project.
#
# All targets are cloud-agnostic and read configuration from environment
# variables set by sourcing env.aws (or a future env.azure).
#
# Usage:
#   source env.aws && make smoke-test
#   source env.aws && make tf-apply

SHELL  := /bin/bash
.PHONY: help deps \
        tf-init tf-plan tf-apply tf-destroy tf-output \
        kubeconfig build registry-login \
        push sign verify smoke-test \
        kyverno-status clean

TAG ?= $(shell git rev-parse --short HEAD 2>/dev/null || echo "dev")

IMAGE_REPO ?= $(error IMAGE_REPO not set — run: source env.aws)
FULL_IMAGE  = $(IMAGE_REPO):$(TAG)

# ── Help ──────────────────────────────────────────────────────────────────────

help:
	@printf "\n"
	@printf "Supply Chain Security — local tooling\n"
	@printf "Active cloud: %s\n\n" "$(or $(CLOUD),not set — source env.aws)"
	@printf "  deps            Check all required CLI tools are present\n\n"
	@printf "  Terraform:\n"
	@printf "    tf-init       terraform init\n"
	@printf "    tf-plan       terraform plan\n"
	@printf "    tf-apply      terraform apply (uses CLOUD env var)\n"
	@printf "    tf-destroy    terraform destroy\n"
	@printf "    tf-output     Print terraform outputs\n\n"
	@printf "  Cluster:\n"
	@printf "    kubeconfig    Update kubeconfig for active cloud\n"
	@printf "    kyverno-status  Show Kyverno pods and ClusterPolicies\n\n"
	@printf "  Image pipeline (source env.aws first):\n"
	@printf "    build         Build the hello-world image\n"
	@printf "    registry-login  Authenticate Docker to the registry\n"
	@printf "    push          Build + push to registry\n"
	@printf "    sign          Sign image with Cosign keyless\n"
	@printf "    verify        Verify Cosign signature\n"
	@printf "    smoke-test    Full end-to-end: push → sign → verify → deploy\n"
	@printf "    clean         Remove local Docker image\n\n"

# ── Deps ──────────────────────────────────────────────────────────────────────

deps:
	@echo "Checking required tools..."
	@for tool in terraform aws az kubectl helm cosign syft docker; do \
		command -v $$tool >/dev/null 2>&1 \
			&& printf "  %-12s %s\n" "$$tool" "$$($$tool version 2>&1 | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)" \
			|| printf "  %-12s NOT FOUND\n" "$$tool"; \
	done

# ── Terraform ─────────────────────────────────────────────────────────────────
# TF_DIR is set based on the CLOUD env var so the same targets work for both
# AWS and Azure without separate make targets.

TF_DIR = terraform/$(or $(CLOUD),$(error CLOUD not set — source env.aws))

TF_VARS_AWS   = -var="github_org=$(GITHUB_ORG)" -var="github_repo=$(GITHUB_REPO)"
TF_VARS_AZURE = -var="github_org=$(GITHUB_ORG)" -var="github_repo=$(GITHUB_REPO)" -var="location=northeurope"
TF_VARS       = $(if $(filter azure,$(CLOUD)),$(TF_VARS_AZURE),$(TF_VARS_AWS))

tf-init:
	cd $(TF_DIR) && terraform init

tf-plan:
	@: $${GITHUB_ORG:?source env.aws first}
	cd $(TF_DIR) && terraform plan $(TF_VARS)

tf-apply:
	@: $${GITHUB_ORG:?source env.aws first}
	cd $(TF_DIR) && terraform apply $(TF_VARS) -auto-approve

tf-destroy:
	@: $${GITHUB_ORG:?source env.aws first}
	cd $(TF_DIR) && terraform destroy $(TF_VARS) -auto-approve

tf-output:
	@cd $(TF_DIR) && terraform output

# ── Cluster ───────────────────────────────────────────────────────────────────

kubeconfig:
	@: $${CLOUD:?source env.aws first}
	@scripts/kubeconfig.sh

kyverno-status: kubeconfig
	@echo "--- Kyverno pods ---"
	kubectl get pods -n kyverno
	@echo ""
	@echo "--- ClusterPolicies ---"
	kubectl get clusterpolicies -o wide 2>/dev/null || echo "(none)"

# ── Image pipeline ────────────────────────────────────────────────────────────

build:
	@echo "Building $(FULL_IMAGE)..."
	docker build -t "$(FULL_IMAGE)" docker/hello-world
	@echo "Built: $(FULL_IMAGE)"

registry-login:
	@: $${CLOUD:?source env.aws first}
	@scripts/registry-login.sh

push: build registry-login
	@echo "Pushing $(FULL_IMAGE)..."
	docker push "$(FULL_IMAGE)"
	@echo "Pushed: $(FULL_IMAGE)"

sign:
	@: $${COSIGN_CERTIFICATE_OIDC_ISSUER:?source env.aws first}
	@scripts/cosign-sign.sh "$(FULL_IMAGE)"

verify:
	@: $${COSIGN_CERTIFICATE_OIDC_ISSUER:?source env.aws first}
	@scripts/cosign-verify.sh "$(FULL_IMAGE)"

smoke-test: push sign verify kubeconfig
	@scripts/smoke-test.sh "$(FULL_IMAGE)"

clean:
	docker rmi "$(FULL_IMAGE)" 2>/dev/null || true