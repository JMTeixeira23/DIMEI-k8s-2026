variable "location" {
  description = "Azure region"
  type        = string
  # NOT northeurope. The AKS resource provider publishes a per-subscription VM
  # allowlist that varies *by region*, and northeurope's is one of the smallest
  # offered to this subscription — 389 sizes, whose only general-purpose D-series
  # entry is the 20 vCPU d15_v2. swedencentral offers 1873 sizes including
  # standard_d2s_v6, which is why the node size below is obtainable at all.
  # Verified clean here and in italynorth, polandcentral and switzerlandnorth;
  # germanywestcentral, francecentral and spaincentral list the size but flag it
  # NotAvailableForSubscription, and westeurope is closed to new customers. (D38)
  default     = "swedencentral"
}

variable "cluster_name" {
  description = "AKS cluster name"
  type        = string
  default     = "supply-chain-aks"
}

variable "cluster_version" {
  description = "Kubernetes version"
  type        = string
  default     = "1.34"
}

variable "node_instance_type" {
  description = "AKS node VM size"
  type        = string
  # 2 vCPU / 8 GiB — the same shape as the Standard_D2s_v3 originally specified,
  # and the same vCPU count as the AWS side (t3.medium, 2 vCPU / 4 GiB). The
  # cross-cloud comparison is therefore unchanged from what the thesis planned.
  #
  # Four gates decide what a new subscription may actually run (D38):
  #   1. the AKS per-subscription VM allowlist — REGIONAL, see var.location
  #   2. the SKU's own NotAvailableForSubscription flag
  #   3. per-family vCPU quota
  #   4. Total Regional vCPUs (10 here, so 2 nodes x 2 vCPU is the practical cap)
  #
  # In swedencentral all four pass: standard_d2s_v6 is on that region's
  # allowlist, carries no restriction, and StandardDsv6Family quota is 10.
  # In northeurope the same size fails gate 1 outright, which is what made
  # Standard_D2s_v3 impossible there and sent this through Standard_B2s_v2
  # (unwinnable — flagged NotAvailableForSubscription, and Azure will not grant
  # quota for a family the subscription cannot use), Standard_DC2as_v6 (quota 0,
  # refused by both the portal and the Microsoft.Quota API) and
  # Standard_NV4as_v4 (a 4 vCPU GPU SKU — the only thing northeurope would have
  # run, and a first-order confound against the AWS node).
  #
  # If this region ever stops working, italynorth, polandcentral and
  # switzerlandnorth were verified to offer the same size unrestricted.
  default     = "Standard_D2s_v6"
}

variable "node_count" {
  description = "Number of AKS nodes"
  type        = number
  default     = 2
}

variable "acr_name" {
  description = "Azure Container Registry name (globally unique, alphanumeric only)"
  type        = string
  default     = "supplychainthesis"
}

variable "github_org" {
  description = "GitHub organisation or username"
  type        = string
}

variable "github_repo" {
  description = "GitHub repository name"
  type        = string
}

variable "resource_group_name" {
  description = "Azure resource group name"
  type        = string
  default     = "supply-chain-rg"
}
