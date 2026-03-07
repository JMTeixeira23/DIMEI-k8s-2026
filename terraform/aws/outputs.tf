output "cluster_name" {
  description = "EKS cluster name"
  value       = aws_eks_cluster.main.name
}

output "cluster_endpoint" {
  description = "EKS API server endpoint"
  value       = aws_eks_cluster.main.endpoint
}

output "cluster_oidc_issuer_url" {
  description = "OIDC issuer URL — used in Cosign verification and Kyverno ClusterPolicies (Phase 3)"
  value       = aws_eks_cluster.main.identity[0].oidc[0].issuer
}

output "ecr_repository_url" {
  description = "Full ECR repository URL — paste into env.aws as IMAGE_REPO"
  value       = aws_ecr_repository.main.repository_url
}

output "github_actions_role_arn" {
  description = "IAM role ARN for GitHub Actions — add as AWS_ROLE_ARN in GitHub repo secrets"
  value       = aws_iam_role.github_actions.arn
}

output "aws_account_id" {
  description = "AWS account ID"
  value       = data.aws_caller_identity.current.account_id
}

output "aws_region" {
  description = "AWS region"
  value       = var.aws_region
}

output "kubeconfig_command" {
  description = "Run this to update your local kubeconfig"
  value       = "aws eks update-kubeconfig --region ${var.aws_region} --name ${aws_eks_cluster.main.name}"
}
