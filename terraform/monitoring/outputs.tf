output "monitoring_instance_id" {
  value = aws_instance.monitoring.id
}

output "monitoring_private_ip" {
  value = aws_instance.monitoring.private_ip
}

output "monitoring_public_ip" {
  value = aws_eip.monitoring_eip.public_ip
}

output "grafana_url" {
  value = "http://${aws_eip.monitoring_eip.public_ip}:3000"
}

output "prometheus_url" {
  value = "http://${aws_eip.monitoring_eip.public_ip}:9090"
}
