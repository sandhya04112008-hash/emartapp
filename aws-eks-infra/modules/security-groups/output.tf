output "alb_sg" {
    value = aws_security_group.lb_sg.id
}

output "internal_sg" {
    value = aws_security_group.eks_node_sg.id
}

output "eks_node_sg" {
    value = aws_security_group.eks_node_sg.id
}

output "db_ng_sg" {
    value = aws_security_group.db-sg-ng.id
  
}

output "mongodb_sg" {
    value = aws_security_group.monogodb-sg-ng.id
}