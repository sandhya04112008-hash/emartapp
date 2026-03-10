output "external_secrets_role_arn" {
  description = "ARN of the External Secrets IAM role"
  value       = aws_iam_role.external_secrets_role.arn
}