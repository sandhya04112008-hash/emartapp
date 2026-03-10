resource "aws_iam_role" "external_secrets_role" {
  name = "${var.cluster_name}-external-secrets-role"
  
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRoleWithWebIdentity"
      Effect = "Allow"
      Principal = {
        Federated = var.oidc_provider_arn
      }
      Condition = {
        StringEquals = {
          "${var.oidc_provider}:sub" = "system:serviceaccount:external-secrets-system:external-secrets"
          "${var.oidc_provider}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })

  tags = {
    Name = "${var.cluster_name}-external-secrets-role"
    Environment = var.environment
    Project = var.project
  }
}

resource "aws_iam_role_policy" "external_secrets_policy" {
  name = "${var.cluster_name}-external-secrets-policy"
  role = aws_iam_role.external_secrets_role.id
  
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "secretsmanager:GetSecretValue",
        "secretsmanager:DescribeSecret"
      ]
      Resource = var.secrets_arn
    }]
  })
}