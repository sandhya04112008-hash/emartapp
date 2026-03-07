resource "aws_iam_policy" "emart_secrets" {
  name = "${var.name}-db-secrets-policy"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "secretsmanager:GetSecretValue",
        "secretsmanager:DescribeSecret"
      ]
      Resource = var.db_secrets_arn
    }]
  })
}

data "aws_eks_cluster" "emart" {
  name = var.cluster_name
}

data "tls_certificate" "eks" {
  url = data.aws_eks_cluster.emart.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "eks" {
  url = data.aws_eks_cluster.emart.identity[0].oidc[0].issuer

  client_id_list = ["sts.amazonaws.com"]

  thumbprint_list = [
    data.tls_certificate.eks.certificates[0].sha1_fingerprint
  ]
}


resource "aws_iam_role" "javaapi_irsa" {
  name = "${var.name}-javaapi-irsa"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = "sts:AssumeRoleWithWebIdentity"

      Principal = {
        Federated = aws_iam_openid_connect_provider.eks.arn
      }

      Condition = {
        StringEquals = {
          "${replace(
            data.aws_eks_cluster.emart.identity[0].oidc[0].issuer,
            "https://",
            ""
          )}:sub" = "system:serviceaccount:emart:javaapi-sa"
        }
      }
    }]
  })
}


resource "aws_iam_role_policy_attachment" "javaapi_secrets_attach" {
  role       = aws_iam_role.javaapi_irsa.name
  policy_arn = aws_iam_policy.emart_secrets.arn
}
