output "monitoring_server_ip" {
  value       = aws_eip.monitoring.public_ip
  description = "Static public IP of the monitoring server (Elastic IP — will not change on restart)"
}

output "grafana_url" {
  value       = "http://${aws_eip.monitoring.public_ip}:3000"
  description = "Grafana dashboard — login: admin / <grafana_admin_password>"
}

output "prometheus_url" {
  value = "http://${aws_eip.monitoring.public_ip}:9090"
}

output "alertmanager_url" {
  value = "http://${aws_eip.monitoring.public_ip}:9093"
}

output "loki_url" {
  value = "http://${aws_eip.monitoring.public_ip}:3100"
}

output "tempo_url" {
  value = "http://${aws_eip.monitoring.public_ip}:3200"
}

output "pushgateway_url" {
  value       = "http://${aws_eip.monitoring.public_ip}:9091"
  description = "Push DORA metrics here from GitHub Actions"
}

output "ssh_command" {
  value = "ssh -i ${var.ssh_private_key_path} ubuntu@${aws_eip.monitoring.public_ip}"
}

output "otlp_grpc_endpoint" {
  value       = "${aws_eip.monitoring.public_ip}:4317"
  description = "Set OTEL_EXPORTER_OTLP_ENDPOINT to this on the application server"
}

output "prometheus_scrape_note" {
  value       = "Allow inbound TCP 9100 from ${aws_eip.monitoring.public_ip} on the app server's firewall so Prometheus can scrape node-exporter"
  description = "Action required on app server after provisioning"
}
