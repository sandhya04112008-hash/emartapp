output "aws_vpc_id" {
    value = aws_vpc.vpc_cidr_emart.id
}

output "emart_public_subnet_id" {
    value = aws_subnet.public_emart_subnet[*].id
}

output "emart_private_subnet_id" {
    value = aws_subnet.private_emart_subnet[*].id
}

output "emart_db_private_subnet_id" {
    value = aws_subnet.db_private_subnet[*].id
}