output "grafana_url" {
  value = "http://${var.server_ip}:3000"
  description = "Grafana dashboard — login with admin and your chosen password"
}

output "prometheus_url" {
  value = "http://${var.server_ip}:9090"
}

output "alertmanager_url" {
  value = "http://${var.server_ip}:9093"
}

output "loki_url" {
  value = "http://${var.server_ip}:3100"
}

output "tempo_url" {
  value = "http://${var.server_ip}:3200"
}

output "sample_app_url" {
  value = "http://${var.server_ip}:8000"
}

output "ssh_command" {
  value = "ssh -i ~/.ssh/social_badge_key teamlead1@${var.server_ip}"
}
