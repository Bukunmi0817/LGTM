output "app_instance_id" {
  value = aws_instance.app.id
}

output "app_private_ip" {
  value = aws_instance.app.private_ip
}

output "app_public_ip" {
  value = aws_eip.app_eip.public_ip
}

output "node_exporter_url" {
  value = "http://${aws_eip.app_eip.public_ip}:9100/metrics"
}
