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
