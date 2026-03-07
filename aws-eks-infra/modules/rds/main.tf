resource "aws_db_subnet_group" "rds_subnet_gp" {
    name = "${var.name}-subnet-group"
    subnet_ids = var.subnet_ids

    tags = {
      Name = "${var.name}-subnet-group"
      environment = "${var.environment}"
    }
}

resource "aws_db_instance" "emart_db" {
    identifier = "${var.name}-db-instance"
    engine = var.engine
    engine_version = var.engine_version


    instance_class = var.db_instance_class
    allocated_storage = var.allocated_storage
    storage_type = var.storage_type
    storage_encrypted = true

    db_name = var.db_name
    username = var.db_username
    password = var.db_password
    port = 3306

    vpc_security_group_ids = [var.security_group_id]
    db_subnet_group_name = aws_db_subnet_group.rds_subnet_gp.name

    multi_az = var.multi_az
    publicly_accessible = false

    # in your aws_db_instance resource
    skip_final_snapshot = true
    final_snapshot_identifier = "${var.name}-final-snapshot-${formatdate("YYYYMMDDhhmmss", timestamp())}"
    backup_retention_period = var.backup_retention_period
    backup_window           = "03:00-04:00"
    maintenance_window      = "mon:04:00-mon:05:00"

    auto_minor_version_upgrade = true
    deletion_protection        = var.deletion_protection

    tags = {
     Name = "${var.name}-db-instance"
     environment = "${var.environment}" 
    }
}