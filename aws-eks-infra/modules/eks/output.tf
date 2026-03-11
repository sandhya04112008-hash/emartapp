output "master_plane_id" {
    value = aws_eks_cluster.eks_cluster_emart.cluster_id 
}

output "node_group_id" {
    value = {
    for k, ng in aws_eks_node_group.emart_node_group :
    k => {
      id   = ng.id
      arn  = ng.arn
      name = ng.node_group_name
    }
  }
}

output "master_oidc_connect" {
  value = aws_eks_cluster.eks_cluster_emart.identity[0].oidc[0].issuer
}

output "oidc_provider_arn" {
  description = "ARN of the OIDC provider for the EKS cluster"
  value       = aws_iam_openid_connect_provider.eks_oidc.arn
}

output "oidc_provider_url" {
  description = "URL of the OIDC provider for the EKS cluster"
  value       = replace(aws_eks_cluster.eks_cluster_emart.identity[0].oidc[0].issuer, "https://", "")
}

output "cluster_security_group_id" {
  description = "Security group ID attached to the EKS cluster"
  value       = aws_eks_cluster.eks_cluster_emart.vpc_config[0].cluster_security_group_id
}

