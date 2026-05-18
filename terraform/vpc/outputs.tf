output "vpc_id" {
  value       = aws_vpc.monitoring_vpc.id
  description = "VPC ID"
}

output "monitoring_subnet_id" {
  value       = aws_subnet.monitoring_subnet.id
  description = "Monitoring subnet ID"
}

output "app_subnet_id" {
  value       = aws_subnet.app_subnet.id
  description = "App subnet ID"
}

output "route_table_id" {
  value       = aws_route_table.monitoring_rt.id
  description = "Route table ID"
}
