# ── AWS infrastructure ─────────────────────────────────────────────────────────

variable "aws_region" {
  description = "AWS region to deploy the monitoring server"
  type        = string
  default     = "us-east-1"
}

variable "instance_type" {
  description = "EC2 instance type for the monitoring server (t3.large is the minimum for the full LGTM stack)"
  type        = string
  default     = "t3.large"
}

variable "app_instance_type" {
  description = "EC2 instance type for the application server"
  type        = string
  default     = "t3.micro"
}

variable "ssh_public_key_path" {
  description = "Local path to the public key to import into AWS as a key pair"
  type        = string
  default     = "~/.ssh/id_ed25519.pub"
}

variable "ssh_private_key_path" {
  description = "Local path to the matching private key — Terraform uses this to SSH in and run lgtm-stack.sh"
  type        = string
  default     = "~/.ssh/id_ed25519"
}

variable "engineer_ips" {
  description = "CIDR blocks for engineers allowed SSH + dashboard access (e.g. [\"203.0.113.1/32\"])"
  type        = list(string)
}

# ── Observability stack config ─────────────────────────────────────────────────

variable "slack_webhook_url" {
  description = "Slack incoming webhook URL for alert notifications"
  type        = string
  sensitive   = true
}

variable "slack_channel" {
  description = "Slack channel name for alerts"
  type        = string
  default     = "#social-badge-devops-alerts"
}

variable "grafana_admin_password" {
  description = "Grafana admin password"
  type        = string
  sensitive   = true
}

variable "duckdns_subdomain" {
  description = "DuckDNS subdomain (without .duckdns.org)"
  type        = string
  default     = "adeshipo-lgtm"
}

variable "duckdns_token" {
  description = "DuckDNS token for SSL certificate provisioning"
  type        = string
  sensitive   = true
}

variable "metrics_retention" {
  description = "Prometheus metrics retention period"
  type        = string
  default     = "15d"
}

variable "logs_retention" {
  description = "Loki log retention in hours"
  type        = number
  default     = 360
}
