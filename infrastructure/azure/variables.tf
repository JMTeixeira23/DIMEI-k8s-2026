variable "location" {
  description = "Azure region"
  type        = string
  default     = "northeurope"
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
  default     = "Standard_D2s_v3"   # ~equivalent to t3.medium
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
