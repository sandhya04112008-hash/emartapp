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

variable "private_subnets"{
    type = list(string)
}

variable "db_private_subnet" {
    type = list(string)
}

variable "cluster_name" {
  type = string
}

variable "node_groups_size" {
    type = map(object({
      instance_type = list(string)
      capacity_type = string 
      scaling_config = object({
        desired_size = number
        max_size = number
        min_size = number 
      })
    }))
}

variable "db_username" {
  type = string
}

variable "db_name" {
  type = string
}

variable "db_instance_class" {
    type = string 
}

variable "engine" {
    type = string
}

variable "engine_version" {
  type = string
}

variable "allocated_storage" {
  type = number
}

variable "storage_type" {
  type = string
}


variable "multi_az" {
  type = bool
}

variable "docdb_engine_version" {
  type = string
  
}

variable "master_username" {
  type = string
}

variable "backup_retention_period" {
  type = number
}

variable "deletion_protection" {
  type = bool
}

variable "docdb_deletion_protection" {
  type = bool
}

variable "docdb_backup_retention_period" {
  type = number
}

variable "docdb_instance_count" {
    type = number
}

variable "docdb_instance_class" {
    type = string
}