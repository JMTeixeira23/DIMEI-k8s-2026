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
  default     = "t3.medium"
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
