variable "aws_region" {
  description = "AWS region to deploy into"
  type        = string
  default     = "eu-west-1"
}

variable "environment" {
  description = "Environment label applied to all resources"
  type        = string
  default     = "thesis-dev"
}

variable "cluster_name" {
  description = "Name of the EKS cluster"
  type        = string
  default     = "supply-chain-eks"
}

variable "cluster_version" {
  description = "Kubernetes version for the EKS cluster"
  type        = string
  default     = "1.34"
}

variable "node_instance_type" {
  description = "EC2 instance type for the managed node group"
  type        = string
  # 2 vCPU / 8 GiB, sustained performance — matched to the Azure side's
  # Standard_D2s_v6 on core count, memory AND CPU model, so the cross-cloud
  # comparison in changes.md §24 is between two clouds rather than between two
  # instance families.
  #
  # Was t3.medium (2 vCPU, 4 GiB, BURSTABLE). That mismatch is the confound
  # §24.3 had to disclose: under a cold cache at 50-way concurrency AWS rejected
  # 20/50 admissions and Azure rejected none, and burstable CPU-credit
  # exhaustion could not be separated from the provider. m7i.large removes both
  # halves of the difference — the memory gap and the CPU model.
  #
  # m7i is Sapphire Rapids, the nearest generation to the Emerald Rapids the
  # Azure D2s_v6 runs on. If it is unavailable in an AZ, m6i.large (Ice Lake) is
  # the fallback and is equally valid — it is still 2 vCPU / 8 GiB sustained.
  # Do NOT fall back to anything burstable; that reinstates the confound.
  #
  # ⚠️ Every AWS performance artefact collected before this change was measured
  # on t3.medium and is NOT comparable to runs made after it. Changing this
  # value obliges a full re-run of the AWS performance suite — see revision.md
  # STEP 9.
  default = "m7i.large"
}

variable "node_desired" {
  description = "Desired number of worker nodes"
  type        = number
  default     = 2
}

variable "node_min" {
  description = "Minimum number of worker nodes"
  type        = number
  default     = 1
}

variable "node_max" {
  description = "Maximum number of worker nodes"
  type        = number
  default     = 3
}

variable "ecr_repo_name" {
  description = "ECR repository name for the supply chain images"
  type        = string
  default     = "supply-chain/hello-world"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "availability_zones" {
  description = "AZs to spread subnets across (minimum 2 for EKS)"
  type        = list(string)
  default     = ["eu-west-1a", "eu-west-1b"]
}

variable "github_org" {
  description = "GitHub organisation or username owning the CI repository"
  type        = string
}

variable "github_repo" {
  description = "GitHub repository name (without org prefix)"
  type        = string
}
