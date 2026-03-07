terraform {
  required_version = ">= 1.14.3"

  required_providers {
    aws = {
      source = "hashicorp/aws"
      version = "~> 6.0"
      }
 }
}

provider "aws" {
    region = "ap-south-1"
}

resource "aws_security_group" "vind_sg" {
  name        = "vind-cluster-sg"
  description = "Security group for vind cluster"

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 8443
    to_port     = 8443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "vind-cluster-sg"
  }
}

resource "aws_instance" "vind-cluster" {
  ami                    = "ami-019715e0d74f695be"
  instance_type          = "m7i-flex.large"
  key_name               = "demo-vind-cluster"
  vpc_security_group_ids = [aws_security_group.vind_sg.id]

  root_block_device {
    volume_size = 40
    volume_type = "gp3"
  }

  user_data = file("${path.module}/userdata.sh")

  tags = {
    Name        = "vind-cluster"
    Environment = "dev"
    project     = "emart-online-store"
  }
}
