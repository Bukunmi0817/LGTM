variable "monitoring_instance_type" {
  type = string
}

variable "instance_ami" {
  type = string
}

variable "monitoring_subnet_id" {
  type = string
}

variable "monitoring_sg_id" {
  type = string
}

variable "project_name" {
  type = string
}

variable "environment" {
  type = string
}

variable "ec2_profile_name" {
  type = string
}

variable "app_server_private_ip" {
  type        = string
  description = "Private IP of app server for Prometheus scraping"
}

variable "app_instance_id" {
  type = string
}
