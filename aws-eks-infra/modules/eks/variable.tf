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

variable "vpc_id" {
  type = string
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


variable "user_principal_arn" {
  description = "ARN of the IAM user to grant EKS cluster access"
  type        = string
}
