terraform {
  backend "s3" {
    bucket = "emart-application-bucket-2026-march"
    key = "dev/terraform.tfstate"
    region = "ap-south-1"
    encrypt = true
    use_lockfile = true   
  }
}