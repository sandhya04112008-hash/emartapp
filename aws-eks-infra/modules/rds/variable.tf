variable "environment" {
    type=string
}

variable "name" {
    type = string
}

variable "project" {
   type = string
}

variable "db_username" {
  type = string
}

variable "db_password" {
    type = string
    sensitive = true
}

variable "db_name" {
  type = string
}

variable "db_instance_class" {
    type = string 
}

variable "subnet_ids" {
    type = list(string)
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

variable "security_group_id" {
    type = string
}

variable "multi_az" {
  type = bool
}

variable "backup_retention_period" {
  type = number
}

variable "deletion_protection" {
  type = bool
}

