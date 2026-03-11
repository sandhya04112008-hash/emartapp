# Get current AWS account ID and region
data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# Generate random password for database
resource "random_password" "db_password" {
  length  = 16
  special = true
  # Exclude characters that might cause issues in connection strings
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

resource "random_password" "docdb_password" {
  length  = 16
  special = true
  # Exclude characters that might cause issues in connection strings
  override_special = "!#$%&*()-_=+[]{}<>:?"
}


module "vpc" {
    source = "../../modules/vpc"

    name = var.name
    environment = var.environment
    project = var.project
    cidr_block = var.cidr_block
    availability_zones = var.availability_zones
    public_subnets = var.public_subnets
    private_subnets = var.private_subnets
    db_private_subnet = var.db_private_subnet
    cluster_name = var.cluster_name
}

module "security_groups"{
    source = "../../modules/security-groups"

    environment = var.environment
    project = var.project
    name = var.name
    vpc_id = module.vpc.aws_vpc_id
}

module "eks" {
    source = "../../modules/eks"

    name = var.name
    environment = var.environment
    project = var.project
    cluster_name = var.cluster_name
    vpc_id = module.vpc.aws_vpc_id
    subnet_ids = module.vpc.emart_private_subnet_id
    node_groups_size = var.node_groups_size
    user_principal_arn = "arn:aws:iam::729127835402:role/access-admin-eks"
    eks_node_security_group_id = module.security_groups.eks_node_sg
}

module "rds" {
    source = "../../modules/rds"
    name = var.name
    environment = var.environment
    project = var.project
    db_username = var.db_username
    db_password = random_password.db_password.result
    db_name = var.db_name
    db_instance_class = var.db_instance_class
    subnet_ids = module.vpc.emart_db_private_subnet_id
    security_group_id = module.security_groups.db_ng_sg
    engine = var.engine
    engine_version = var.engine_version
    allocated_storage = var.allocated_storage
    storage_type = var.storage_type
    multi_az = var.multi_az
    backup_retention_period = var.backup_retention_period
    deletion_protection = var.deletion_protection
}

# module "documentdb" {
#     source = "../../modules/documentdb"

#     name = var.name
#     environment = var.environment
#     project = var.project
#     subnet_ids = module.vpc.emart_db_private_subnet_id
#     security_group_id = module.security_groups.db_ng_sg
#     docdb_engine_version = var.docdb_engine_version
#     master_username = var.master_username
#     master_password = random_password.docdb_password.result
#     docdb_deletion_protection = var.docdb_deletion_protection
#     docdb_backup_retention_period = var.docdb_backup_retention_period
#     docdb_instance_count = var.docdb_instance_count
#     docdb_instance_class = var.docdb_instance_class

# }

module "secrets" {
    source = "../../modules/secrets"

    name = var.name
    environment = var.environment
    project = var.project
    db_username = var.db_username
    db_password = random_password.db_password.result
    db_name = var.db_name
    db_endpoint = module.rds.rds_endpoint
}

module "iam" {
    source = "../../modules/iam"

    cluster_name = var.cluster_name
    environment = var.environment
    project = var.project
    oidc_provider_arn = module.eks.oidc_provider_arn
    oidc_provider = module.eks.oidc_provider_url
    secrets_arn = module.secrets.secret_arn
}

# Add security group rule to allow EKS cluster security group to access RDS
resource "aws_security_group_rule" "rds_from_eks_cluster" {
  type                     = "ingress"
  from_port                = 3306
  to_port                  = 3306
  protocol                 = "tcp"
  source_security_group_id = module.eks.cluster_security_group_id
  security_group_id        = module.security_groups.db_ng_sg
  description              = "Allow MySQL access from EKS cluster security group"
}

# module "iam" {
#     source = "../../modules/iam"

#     name = var.name
#     master_oidc_connect = module.eks.master_oidc_connect
#     db_secrets_arn = module.secrets.secret_arn
#     cluster_name = var.cluster_name
# }