output "rds_db_name" {
    value = aws_db_instance.emart_db.db_name
}

output "rds_username" {
    value = aws_db_instance.emart_db.username
}

output "rds_endpoint" {
    value = aws_db_instance.emart_db.endpoint
}

output "rds_address" {
    value = aws_db_instance.emart_db.address
}