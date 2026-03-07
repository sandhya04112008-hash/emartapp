resource "aws_docdb_subnet_group" "docdb_subnet_group" {
  name       = "${var.name}-docdb-subnet-group"
  subnet_ids = var.subnet_ids

  tags = {
    Name        = "${var.name}-docdb-subnet-group"
    environment = var.environment
    project     = var.project
  }
}

resource "aws_docdb_cluster" "docdb_cluster" {
  cluster_identifier = "${var.name}-docdb-cluster"

  engine = "docdb"
  engine_version = var.docdb_engine_version   # e.g. 5.0.0

  master_username = var.master_username
  master_password = var.master_password

  port = 27017

  db_subnet_group_name   = aws_docdb_subnet_group.docdb_subnet_group.name
  vpc_security_group_ids = [var.security_group_id]

  storage_encrypted = true
  deletion_protection = var.docdb_deletion_protection

  backup_retention_period = var.docdb_backup_retention_period
  preferred_backup_window = "03:00-04:00"

  skip_final_snapshot = true   # change in prod

  tags = {
    Name        = "${var.name}-docdb-cluster"
    environment = var.environment
    project     = var.project
  }
}

resource "aws_docdb_cluster_instance" "docdb_instances" {
  count = var.docdb_instance_count

  identifier         = "${var.name}-docdb-instance-${count.index + 1}"
  cluster_identifier = aws_docdb_cluster.docdb_cluster.id

  instance_class = var.docdb_instance_class   # e.g. db.t3.medium

  tags = {
    Name        = "${var.name}-docdb-instance-${count.index + 1}"
    environment = var.environment
    project     = var.project
  }
}
