output "external_secrets_role_arn" {
  description = "ARN of the External Secrets IAM role"
  value       = module.iam.external_secrets_role_arn
}

output "rds_endpoint" {
  description = "RDS instance endpoint"
  value       = module.rds.rds_endpoint
}

output "cluster_name" {
  description = "EKS cluster name"
  value       = var.cluster_name
}