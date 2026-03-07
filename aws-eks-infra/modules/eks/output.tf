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

