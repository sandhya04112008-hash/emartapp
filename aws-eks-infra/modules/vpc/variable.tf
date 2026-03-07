variable "name" {
    type = string
}

variable "environment" {
    type = string
}

variable "project" {
    type = string
}

variable "cidr_block" {
    type = string
}

variable "availability_zones" {
  type = list(string)
}

variable "public_subnets" {
    type = list(string)
}

variable "private_subnets" {
    type = list(string)
}

variable "db_private_subnet" {
    type = list(string)
}

variable "cluster_name" {
  type = string
}