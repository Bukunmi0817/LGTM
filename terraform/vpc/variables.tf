variable "vpc_cidr" {
  description = "CIDR block for VPC"
  type        = string
}

variable "monitoring_subnet_cidr" {
  description = "CIDR block for monitoring subnet"
  type        = string
}

variable "app_subnet_cidr" {
  description = "CIDR block for app subnet"
  type        = string
}

variable "project_name" {
  description = "Project name"
  type        = string
}

variable "environment" {
  description = "Environment"
  type        = string
}
