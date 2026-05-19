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
  description = "Push DORA metrics here from GitHub Actions — store as PUSHGATEWAY_URL secret"
}

# ── GitHub Actions secrets ─────────────────────────────────────────────────────
# Run `terraform output github_actions_secrets` after apply to get the exact
# values to paste into: GitHub repo → Settings → Secrets and variables → Actions
output "github_actions_secrets" {
  value = {
    MONITOR_SERVER_IP = aws_eip.monitoring.public_ip
    PUSHGATEWAY_URL   = "http://${aws_eip.monitoring.public_ip}:9091"
  }
  description = "Values to store as GitHub Actions secrets. MONITOR_SSH_KEY must be set manually (private key content)."
}

output "ssh_command" {
  value = "ssh -i ${var.ssh_private_key_path} ubuntu@${aws_eip.monitoring.public_ip}"
}

output "otlp_grpc_endpoint" {
  value       = "${aws_eip.monitoring.public_ip}:4317"
  description = "Tempo OTLP gRPC endpoint — app server OTel Collector forwards traces here"
}

output "app_server_public_ip" {
  value       = aws_instance.app.public_ip
  description = "Public IP of the application server (ephemeral — may change on stop/start)"
}

output "fake_service_url" {
  value       = "http://${aws_instance.app.public_ip}:8080"
  description = "Fake service endpoint — open to internet for demo traffic"
}

output "app_ssh_command" {
  value       = "ssh -i ${var.ssh_private_key_path} ubuntu@${aws_instance.app.public_ip}"
  description = "SSH into the application server"
}

output "chaos_script_note" {
  value       = "On the app server: sudo /opt/fake-service/chaos.sh [error-burst|latency-spike|normal|check]"
  description = "Trigger failure scenarios for dashboard testing"
}
