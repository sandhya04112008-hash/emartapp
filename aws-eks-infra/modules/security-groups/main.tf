resource "aws_security_group" "lb_sg" {
    vpc_id = var.vpc_id
    name = "${var.name}-alb-sg"
    description = "security group for load balancer to allow traffic from eks cluster"
    
    ingress {
        from_port = 80
        to_port = 80
        protocol = "tcp"
        cidr_blocks = ["0.0.0.0/0"]
    }
    ingress {
         from_port = 443
        to_port = 443
        protocol = "tcp"
        cidr_blocks = ["0.0.0.0/0"]
    }
    egress{
        from_port = 0
        to_port = 0
        protocol = "-1"
        cidr_blocks = ["0.0.0.0/0"]
    }
    tags = {
      Name = "${var.name}-alb-sg"
    }
}

resource "aws_security_group" "eks_node_sg" {
    vpc_id = var.vpc_id
    name = "${var.name}-eks-node-sg"
    description  = "security group for eks nodes to allow traffic from load balancer"

    ingress {
        from_port = 30000
        to_port = 32767
        protocol = "tcp"
        security_groups = [aws_security_group.lb_sg.id]
    }
    egress {
        from_port = 0
        to_port = 0
        protocol = "-1"
        cidr_blocks = ["0.0.0.0/0"]
    }
    tags = {
      Name = "${var.name}-eks-node-sg"
    }
}

resource "aws_security_group" "db-sg-ng" {
    vpc_id = var.vpc_id
    name = "${var.name}-db-ng-sg"
    description = "security group for db instance to  allow traffic from eks nodes to dbinstance"

    ingress {
        from_port = 3306
        to_port = 3306
        protocol = "tcp"
        security_groups = [aws_security_group.eks_node_sg.id]
    }
    egress {
        from_port = 0
        to_port = 0
        protocol = "-1"
        cidr_blocks = ["0.0.0.0/0"]
    }
    tags = {
      Name = "${var.name}-db-ng-sg"
    }
}

resource "aws_security_group" "monogodb-sg-ng" {
    vpc_id = var.vpc_id
    name = "${var.name}-mongodb-ng-sg"
    description = "security group for mongodb instance to  allow traffic from eks nodes to mongodb"

    ingress {
        from_port = 27017
        to_port = 27017
        protocol = "tcp"
        security_groups = [aws_security_group.eks_node_sg.id]
    }
    egress {
        from_port = 0
        to_port = 0
        protocol = "-1"
        cidr_blocks = ["0.0.0.0/0"]
    }
    tags = {
      Name = "${var.name}-mongodb-ng-sg"
    }
}