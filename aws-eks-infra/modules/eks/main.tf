resource "aws_iam_role" "eks_cluster_role" {
    name = "${var.cluster_name}-eks-cluster-role"

    assume_role_policy =  jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = [
          "sts:AssumeRole",
          "sts:TagSession"
        ]
        Effect = "Allow"
        Principal = {
          Service = "eks.amazonaws.com"
        }
      },
    ]
  })
}

resource "aws_iam_role_policy_attachment" "cluster_AmazonEKSClusterPolicy" {
     policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
     role       = aws_iam_role.eks_cluster_role.name
} 

resource "aws_eks_cluster" "eks_cluster_emart" {
    name = var.cluster_name

    access_config {
      authentication_mode = "API"
    }

    role_arn = aws_iam_role.eks_cluster_role.arn
    version = "1.31"

    vpc_config {
      subnet_ids = var.subnet_ids 
    }

    tags = {
      Name = "${var.cluster_name}-eks-cluster"
      environment = var.environment
      project = var.project
    }

    depends_on = [ aws_iam_role_policy_attachment.cluster_AmazonEKSClusterPolicy ]
}

resource "aws_iam_role" "node_group_role" {
    name = "${var.cluster_name}-node-group-role"
    
    assume_role_policy = jsonencode({
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
    }]
    Version = "2012-10-17"
  })
}

resource "aws_iam_role_policy_attachment" "node_group_WorkerNodePolicy" {
    for_each = toset([
        "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy",
        "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy",
        "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
    ])
    policy_arn = each.value
    role = aws_iam_role.node_group_role.name
}

# Comment out launch template temporarily
# resource "aws_launch_template" "node_group_lt" {
#   for_each = var.node_groups_size
#   
#   name_prefix   = "${var.cluster_name}-${each.key}-"
#   image_id      = data.aws_ssm_parameter.eks_ami_release_version.value
#   instance_type = each.value.instance_type[0]
#   
#   vpc_security_group_ids = var.eks_node_security_group_id != "" ? [
#     aws_eks_cluster.eks_cluster_emart.vpc_config[0].cluster_security_group_id,
#     var.eks_node_security_group_id
#   ] : [aws_eks_cluster.eks_cluster_emart.vpc_config[0].cluster_security_group_id]
#   
#   tag_specifications {
#     resource_type = "instance"
#     tags = {
#       Name = "${var.cluster_name}-${each.key}-node"
#       Environment = var.environment
#       Project = var.project
#       NodeGroup = each.key
#       "kubernetes.io/cluster/${var.cluster_name}" = "owned"
#     }
#   }
#   
#   tag_specifications {
#     resource_type = "volume"
#     tags = {
#       Name = "${var.cluster_name}-${each.key}-node-volume"
#       Environment = var.environment
#       Project = var.project
#     }
#   }
#   
#   tags = {
#     Name = "${var.cluster_name}-${each.key}-launch-template"
#     Environment = var.environment
#     Project = var.project
#   }
# }

# Comment out SSM parameter lookup
# data "aws_ssm_parameter" "eks_ami_release_version" {
#   name = "/aws/service/eks/optimized-ami/1.31/amazon-linux-2/recommended/image_id"
# }

resource "aws_eks_node_group" "emart_node_group" {
    for_each = var.node_groups_size
    cluster_name = var.cluster_name
    node_group_name = "${var.cluster_name}-${each.key}node-group"
    node_role_arn = aws_iam_role.node_group_role.arn
    subnet_ids = var.subnet_ids

    instance_types = each.value.instance_type
    capacity_type = each.value.capacity_type

    scaling_config {
      desired_size = each.value.scaling_config.desired_size
      max_size = each.value.scaling_config.max_size
      min_size = each.value.scaling_config.min_size
    }

    tags = {
      Name = "${var.cluster_name}-${each.key}-node-group"
      Environment = var.environment
      Project = var.project
    }

    depends_on = [ aws_iam_role_policy_attachment.node_group_WorkerNodePolicy ]
}

resource "aws_eks_access_entry" "user_access" {
  cluster_name  = aws_eks_cluster.eks_cluster_emart.name
  principal_arn = var.user_principal_arn
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "user_policy" {
  cluster_name  = aws_eks_cluster.eks_cluster_emart.name
  principal_arn = var.user_principal_arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
  access_scope {
    type = "cluster"
  }

  depends_on = [aws_eks_access_entry.user_access]
}

# OIDC Provider for IRSA
data "tls_certificate" "eks_oidc" {
  url = aws_eks_cluster.eks_cluster_emart.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "eks_oidc" {
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks_oidc.certificates[0].sha1_fingerprint]
  url             = aws_eks_cluster.eks_cluster_emart.identity[0].oidc[0].issuer

  tags = {
    Name = "${var.cluster_name}-oidc-provider"
    Environment = var.environment
    Project = var.project
  }
}
