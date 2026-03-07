variable "name" {
    type = string
}

variable "environment" {
    type = string
}

variable "project" {
    type = string
}

variable "subnet_ids" {
    type = list(string)
}

variable "docdb_engine_version" {
  type = string
}

variable "master_username" {
  type = string
}

variable "master_password" {
  type = string
  sensitive = true
}

variable "security_group_id" {
  type = string
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