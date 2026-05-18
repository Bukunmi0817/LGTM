# Security Group for Monitoring Server
resource "aws_security_group" "monitoring_sg" {
  name        = "${var.project_name}-monitoring-sg"
  description = "Security group for monitoring stack"
  vpc_id      = var.vpc_id

  tags = {
    Name        = "${var.project_name}-monitoring-sg"
    Environment = var.environment
  }
}

# Allow SSH from team IPs
resource "aws_security_group_rule" "monitoring_ssh" {
  type              = "ingress"
  from_port         = 22
  to_port           = 22
  protocol          = "tcp"
  cidr_blocks       = var.team_ips
  security_group_id = aws_security_group.monitoring_sg.id
  description       = "SSH from team IPs"
}

# Allow Grafana (3000) from team IPs
resource "aws_security_group_rule" "monitoring_grafana" {
  type              = "ingress"
  from_port         = 3000
  to_port           = 3000
  protocol          = "tcp"
  cidr_blocks       = var.team_ips
  security_group_id = aws_security_group.monitoring_sg.id
  description       = "Grafana access from team IPs"
}

# Allow Prometheus (9090) from team IPs
resource "aws_security_group_rule" "monitoring_prometheus" {
  type              = "ingress"
  from_port         = 9090
  to_port           = 9090
  protocol          = "tcp"
  cidr_blocks       = var.team_ips
  security_group_id = aws_security_group.monitoring_sg.id
  description       = "Prometheus access from team IPs"
}

# Allow Alertmanager (9093) from team IPs
resource "aws_security_group_rule" "monitoring_alertmanager" {
  type              = "ingress"
  from_port         = 9093
  to_port           = 9093
  protocol          = "tcp"
  cidr_blocks       = var.team_ips
  security_group_id = aws_security_group.monitoring_sg.id
  description       = "Alertmanager access from team IPs"
}

# Allow all monitoring ports internally (from app subnet)
resource "aws_security_group_rule" "monitoring_internal" {
  type                     = "ingress"
  from_port                = 3000
  to_port                  = 9115
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.app_sg.id
  security_group_id        = aws_security_group.monitoring_sg.id
  description              = "Internal monitoring access from app servers"
}

# Allow all outbound
resource "aws_security_group_rule" "monitoring_egress" {
  type              = "egress"
  from_port         = 0
  to_port           = 65535
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.monitoring_sg.id
  description       = "Allow all outbound traffic"
}

# ============================================================
# Security Group for App Server
# ============================================================

resource "aws_security_group" "app_sg" {
  name        = "${var.project_name}-app-sg"
  description = "Security group for application server"
  vpc_id      = var.vpc_id

  tags = {
    Name        = "${var.project_name}-app-sg"
    Environment = var.environment
  }
}

# Allow SSH from team IPs
resource "aws_security_group_rule" "app_ssh" {
  type              = "ingress"
  from_port         = 22
  to_port           = 22
  protocol          = "tcp"
  cidr_blocks       = var.team_ips
  security_group_id = aws_security_group.app_sg.id
  description       = "SSH from team IPs"
}

# Allow app port (8080) from team IPs
resource "aws_security_group_rule" "app_port" {
  type              = "ingress"
  from_port         = 8080
  to_port           = 8080
  protocol          = "tcp"
  cidr_blocks       = var.team_ips
  security_group_id = aws_security_group.app_sg.id
  description       = "App port access from team IPs"
}

# Allow Node Exporter (9100) from monitoring server
resource "aws_security_group_rule" "app_node_exporter" {
  type                     = "ingress"
  from_port                = 9100
  to_port                  = 9100
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.monitoring_sg.id
  security_group_id        = aws_security_group.app_sg.id
  description              = "Node Exporter access from monitoring server"
}

# Allow all outbound
resource "aws_security_group_rule" "app_egress" {
  type              = "egress"
  from_port         = 0
  to_port           = 65535
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.app_sg.id
  description       = "Allow all outbound traffic"
}
