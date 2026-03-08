# ─────────────────────────────────────────────────────────────────────────────
# DATA SOURCES
# ─────────────────────────────────────────────────────────────────────────────

data "azurerm_client_config" "current" {}
data "azuread_client_config" "current" {}

# ─────────────────────────────────────────────────────────────────────────────
# RESOURCE GROUP
# Azure equivalent of an AWS account/region scope.
# All resources for this thesis cluster live in one RG for easy cleanup.
# ─────────────────────────────────────────────────────────────────────────────

resource "azurerm_resource_group" "main" {
  name     = var.resource_group_name
  location = var.location
  tags     = { project = "supply-chain-thesis" }
}

# ─────────────────────────────────────────────────────────────────────────────
# AZURE CONTAINER REGISTRY (ACR)
# AWS equivalent: ECR
# Premium SKU required for geo-replication; Standard is sufficient here.
# Retention policy: keep last 30 images (same as ECR lifecycle policy).
# ─────────────────────────────────────────────────────────────────────────────

resource "azurerm_container_registry" "main" {
  name                = var.acr_name
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  sku                 = "Standard"

  # Admin account disabled — access via managed identity only (no static creds)
  admin_enabled = false

  tags = { project = "supply-chain-thesis" }
}


# ─────────────────────────────────────────────────────────────────────────────
# AKS CLUSTER
# AWS equivalent: EKS
# OIDC issuer enabled — required for Workload Identity (Azure equivalent of IRSA)
# ─────────────────────────────────────────────────────────────────────────────

resource "azurerm_kubernetes_cluster" "main" {
  name                = var.cluster_name
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  dns_prefix          = var.cluster_name
  kubernetes_version  = var.cluster_version

  default_node_pool {
    name       = "system"
    node_count = var.node_count
    vm_size    = var.node_instance_type

    # Use latest OS — Azure equivalent of AL2023
    os_sku = "Ubuntu"
  }

  # Managed identity for the cluster control plane
  # AWS equivalent: EKS cluster IAM role
  identity {
    type = "SystemAssigned"
  }

  # Enable OIDC issuer — required for Workload Identity (Kyverno IRSA equivalent)
  oidc_issuer_enabled       = true
  workload_identity_enabled = true

  # Azure Monitor integration (equivalent to CloudWatch/EKS audit logs)
  monitor_metrics {}

  tags = { project = "supply-chain-thesis" }
}

# ─────────────────────────────────────────────────────────────────────────────
# ACR PULL PERMISSION FOR AKS
# Allows AKS nodes to pull images from ACR.
# AWS equivalent: AmazonEC2ContainerRegistryReadOnly on the node role.
# ─────────────────────────────────────────────────────────────────────────────

resource "azurerm_role_assignment" "aks_acr_pull" {
  principal_id                     = azurerm_kubernetes_cluster.main.kubelet_identity[0].object_id
  role_definition_name             = "AcrPull"
  scope                            = azurerm_container_registry.main.id
  skip_service_principal_aad_check = true
}

# ─────────────────────────────────────────────────────────────────────────────
# GITHUB ACTIONS — ENTRA WORKLOAD IDENTITY FEDERATION
# AWS equivalent: aws_iam_openid_connect_provider.github_actions + IAM role
#
# Azure uses an Entra ID application + federated credential instead of an
# IAM role. GitHub Actions exchanges its OIDC token for an Entra access token.
# No client secrets stored anywhere.
# ─────────────────────────────────────────────────────────────────────────────

resource "azuread_application" "github_actions" {
  display_name = "${var.cluster_name}-github-actions"
}

resource "azuread_service_principal" "github_actions" {
  client_id = azuread_application.github_actions.client_id
}

# Federated credential — trusts tokens from GitHub Actions for your repo
resource "azuread_application_federated_identity_credential" "github_actions" {
  application_id = azuread_application.github_actions.id
  display_name   = "github-actions-oidc"
  description    = "GitHub Actions OIDC federation for ${var.github_org}/${var.github_repo}"

  audiences = ["api://AzureADTokenExchange"]
  issuer    = "https://token.actions.githubusercontent.com"

  # Scoped to your repo — prevents other repos using this credential
  # Workflows using environment: send "environment:NAME" not "ref:..." as subject
  subject = "repo:${var.github_org}/${var.github_repo}:environment:azure"
}

# ─────────────────────────────────────────────────────────────────────────────
# RBAC — GitHub Actions permissions
# Push to ACR + manage AKS
# AWS equivalent: github_actions_ecr + github_actions_eks_read IAM policies
# ─────────────────────────────────────────────────────────────────────────────

# ACR push — allows CI to push images and Cosign artefacts
resource "azurerm_role_assignment" "github_actions_acr_push" {
  principal_id         = azuread_service_principal.github_actions.object_id
  role_definition_name = "AcrPush"
  scope                = azurerm_container_registry.main.id
}

# AKS cluster user — allows CI to get kubeconfig and run kubectl
resource "azurerm_role_assignment" "github_actions_aks_user" {
  principal_id         = azuread_service_principal.github_actions.object_id
  role_definition_name = "Azure Kubernetes Service Cluster User Role"
  scope                = azurerm_kubernetes_cluster.main.id
}

# AKS admin — allows CI to manage cluster resources (smoke tests, Phase 3-5)
resource "azurerm_role_assignment" "github_actions_aks_admin" {
  principal_id         = azuread_service_principal.github_actions.object_id
  role_definition_name = "Azure Kubernetes Service RBAC Cluster Admin"
  scope                = azurerm_kubernetes_cluster.main.id
}

# ─────────────────────────────────────────────────────────────────────────────
# KYVERNO WORKLOAD IDENTITY
# AWS equivalent: aws_iam_role.kyverno_ecr (IRSA)
#
# Kyverno pods need to pull from ACR to verify image signatures.
# Azure Workload Identity federated with the AKS OIDC issuer — same concept
# as IRSA but Azure-native.
# ─────────────────────────────────────────────────────────────────────────────

resource "azuread_application" "kyverno" {
  display_name = "${var.cluster_name}-kyverno"
}

resource "azuread_service_principal" "kyverno" {
  client_id = azuread_application.kyverno.client_id
}

# Federated credential — trusts the Kyverno service account in AKS
resource "azuread_application_federated_identity_credential" "kyverno" {
  application_id = azuread_application.kyverno.id
  display_name   = "kyverno-aks-workload-identity"
  description    = "Kyverno admission controller workload identity"

  audiences = ["api://AzureADTokenExchange"]
  issuer    = azurerm_kubernetes_cluster.main.oidc_issuer_url

  # Must match: system:serviceaccount:<namespace>:<service-account-name>
  subject = "system:serviceaccount:kyverno:kyverno-admission-controller"
}

# ACR pull for Kyverno — allows signature/attestation verification
resource "azurerm_role_assignment" "kyverno_acr_pull" {
  principal_id         = azuread_service_principal.kyverno.object_id
  role_definition_name = "AcrPull"
  scope                = azurerm_container_registry.main.id
}
