resource  "aws_secretsmanager_secret" "db_credentials" {
    name = "${var.name}-db-credentials-dev-app"
     recovery_window_in_days = 7   

     lifecycle {
    # Prevent accidental deletion in production
    prevent_destroy = false
  }

    tags = {
        Name = "${var.name}-db-credentials"
        environment = var.environment
    }
}

resource "aws_secretsmanager_secret_version" "db_credentials_version" {
    secret_id = aws_secretsmanager_secret.db_credentials.id
    secret_string = jsonencode({
        username = var.db_username
        password = var.db_password
        db_name = var.db_name
        db_endpoint = var.db_endpoint
        port = 3306
        engine = "mysql"
    })
}