variable "server_ip" {
  description = "IP address of the server provided by your team"
  type        = string
  default     = "13.61.147.12"
}

variable "ssh_user" {
  description = "SSH username for the server"
  type        = string
  default     = "teamlead1"
}

variable "ssh_key_path" {
  description = "Path to your SSH private key"
  type        = string
  default     = "~/.ssh/social_badge_key"
}

variable "slack_webhook_url" {
  description = "Slack incoming webhook URL for #social-badge-devops-alerts"
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
  description = "DuckDNS token for SSL certificate"
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
