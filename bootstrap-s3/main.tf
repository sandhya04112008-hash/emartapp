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


resource "aws_s3_bucket" "emart_main"{
    bucket = "emart-application-bucket-2026-march"
    
    tags = {
        Name = "emart-application-bucket-2026-march"
        Environment = "dev"
        project = "emart-online-store"
    }
}

resource "aws_s3_bucket_public_access_block" "tf_state_block" {
    bucket = aws_s3_bucket.emart_main.id
  
    block_public_acls = true
    block_public_policy = true
    ignore_public_acls = true
    restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tf_state_configuration" {
    bucket = aws_s3_bucket.emart_main.id
    
     rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}