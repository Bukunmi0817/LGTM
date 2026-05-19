locals {
  domain      = "${var.duckdns_subdomain}.duckdns.org"
  grafana_url = "http://${aws_eip.monitoring.public_ip}:3000"
}

# ── Account ID (used to scope IAM policy to this account's SSM parameters) ────
data "aws_caller_identity" "current" {}

# ── SSM Parameter Store: secrets the bootstrap script fetches at runtime ───────
# SecureString parameters are encrypted with the AWS-managed SSM KMS key.
# Values are stored here rather than in Terraform state plaintext or SSH env vars.
resource "aws_ssm_parameter" "slack_webhook_url" {
  name  = "/lgtm/slack_webhook_url"
  type  = "SecureString"
  value = var.slack_webhook_url
}

resource "aws_ssm_parameter" "grafana_admin_password" {
  name  = "/lgtm/grafana_admin_password"
  type  = "SecureString"
  value = var.grafana_admin_password
}

resource "aws_ssm_parameter" "duckdns_token" {
  name  = "/lgtm/duckdns_token"
  type  = "SecureString"
  value = var.duckdns_token
}

resource "aws_ssm_parameter" "duckdns_subdomain" {
  name  = "/lgtm/duckdns_subdomain"
  type  = "String"
  value = var.duckdns_subdomain
}

# ── IAM role: lets the EC2 instance read /lgtm/* SSM parameters ───────────────
resource "aws_iam_role" "monitoring" {
  name = "lgtm-monitoring-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "monitoring_ssm" {
  name = "lgtm-monitoring-ssm-read"
  role = aws_iam_role.monitoring.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["ssm:GetParameter", "ssm:GetParameters"]
        Resource = "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter/lgtm/*"
      },
      {
        # Allow KMS decrypt only when called via SSM (scoped to the managed SSM key)
        Effect    = "Allow"
        Action    = "kms:Decrypt"
        Resource  = "*"
        Condition = { StringEquals = { "kms:ViaService" = "ssm.${var.aws_region}.amazonaws.com" } }
      }
    ]
  })
}

resource "aws_iam_instance_profile" "monitoring" {
  name = "lgtm-monitoring-profile"
  role = aws_iam_role.monitoring.name
}

# ── AMI: latest Ubuntu 22.04 LTS (Canonical) ──────────────────────────────────
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# ── VPC and public subnet ──────────────────────────────────────────────────────
resource "aws_vpc" "monitoring" {
  cidr_block           = "10.100.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "lgtm-monitoring-vpc" }
}

resource "aws_subnet" "monitoring_public" {
  vpc_id                  = aws_vpc.monitoring.id
  cidr_block              = "10.100.1.0/24"
  availability_zone       = "${var.aws_region}a"
  map_public_ip_on_launch = false

  tags = { Name = "lgtm-monitoring-public" }
}

resource "aws_internet_gateway" "monitoring" {
  vpc_id = aws_vpc.monitoring.id

  tags = { Name = "lgtm-monitoring-igw" }
}

resource "aws_route_table" "monitoring_public" {
  vpc_id = aws_vpc.monitoring.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.monitoring.id
  }

  tags = { Name = "lgtm-monitoring-rt" }
}

resource "aws_route_table_association" "monitoring_public" {
  subnet_id      = aws_subnet.monitoring_public.id
  route_table_id = aws_route_table.monitoring_public.id
}

# ── Security group ─────────────────────────────────────────────────────────────
# Inbound default-deny: only the ports below are open and only to the listed
# CIDRs. Outbound unrestricted so Prometheus can scrape app-server node-exporter
# (:9100) and Blackbox can probe app endpoints.
resource "aws_security_group" "monitoring" {
  name        = "lgtm-monitoring-sg"
  description = "LGTM monitoring - engineer access + app server telemetry only"
  vpc_id      = aws_vpc.monitoring.id

  ingress {
    description = "SSH from engineers"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = var.engineer_ips
  }

  ingress {
    description = "Grafana from engineers"
    from_port   = 3000
    to_port     = 3000
    protocol    = "tcp"
    cidr_blocks = var.engineer_ips
  }

  ingress {
    description = "Prometheus UI from engineers"
    from_port   = 9090
    to_port     = 9090
    protocol    = "tcp"
    cidr_blocks = var.engineer_ips
  }

  ingress {
    description = "Alertmanager UI from engineers"
    from_port   = 9093
    to_port     = 9093
    protocol    = "tcp"
    cidr_blocks = var.engineer_ips
  }

  # Pushgateway is open to 0.0.0.0/0 so GitHub Actions can push DORA metrics
  # directly from the runner without needing SSH. Pushgateway has no built-in
  # auth — access relies on the IP being non-guessable (Elastic IP, not public
  # DNS). For higher security, add a reverse proxy with bearer token auth.
  ingress {
    description = "Pushgateway is open for GitHub Actions DORA metric pushes"
    from_port   = 9091
    to_port     = 9091
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Cross-server ingress rules (OTLP, Loki) are added via aws_security_group_rule
  # resources below, after aws_instance.app exists and its private IP is known.

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "lgtm-monitoring-sg" }
}

# ── Key pair: import your local public key into AWS ────────────────────────────
resource "aws_key_pair" "monitoring" {
  key_name   = "lgtm-monitoring-key"
  public_key = file(var.ssh_public_key_path)

  tags = { Name = "lgtm-monitoring-key" }
}

# ── EC2 instance ───────────────────────────────────────────────────────────────
resource "aws_instance" "monitoring" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  key_name               = aws_key_pair.monitoring.key_name
  subnet_id              = aws_subnet.monitoring_public.id
  vpc_security_group_ids = [aws_security_group.monitoring.id]
  iam_instance_profile   = aws_iam_instance_profile.monitoring.name

  root_block_device {
    volume_type           = "gp3"
    volume_size           = 40 # Prometheus TSDB + Loki chunks + Tempo trace blocks
    delete_on_termination = true
  }

  tags = { Name = "lgtm-monitoring" }
}

# ── Elastic IP ─────────────────────────────────────────────────────────────────
resource "aws_eip" "monitoring" {
  domain = "vpc"
  tags   = { Name = "lgtm-monitoring-eip" }
}

resource "aws_eip_association" "monitoring" {
  instance_id   = aws_instance.monitoring.id
  allocation_id = aws_eip.monitoring.id
}

# ── Bootstrap: upload and run lgtm-stack.sh ───────────────────────────────────
# Secrets are written to a 600-permissions env file uploaded via the encrypted
# SSH session, sourced into the script, then immediately deleted. Values are
# still stored in Terraform state — use an encrypted S3 backend with restricted
# access policies to protect them at rest.
resource "null_resource" "bootstrap" {
  triggers = {
    instance_id = aws_instance.monitoring.id
  }

  depends_on = [
    aws_eip_association.monitoring,
    aws_ssm_parameter.app_server_ip,
    aws_ssm_parameter.monitoring_server_ip,
  ]

  connection {
    type        = "ssh"
    user        = "ubuntu"
    private_key = file(var.ssh_private_key_path)
    host        = aws_eip.monitoring.public_ip
    timeout     = "10m"
  }

  # Wait for cloud-init to finish initialising the instance before anything else
  provisioner "remote-exec" {
    inline = ["cloud-init status --wait || true"]
  }

  provisioner "remote-exec" {
    inline = ["mkdir -p /tmp/lgtm-dashboards"]
  }

  provisioner "file" {
    source      = "../dashboards/"
    destination = "/tmp/lgtm-dashboards"
  }

  provisioner "file" {
    source      = "../scripts/lgtm-stack.sh"
    destination = "/tmp/lgtm-stack.sh"
  }

  # The script fetches SLACK_WEBHOOK_URL and GRAFANA_PASSWORD directly from
  # SSM using the instance's IAM role — no secrets flow through SSH.
  provisioner "remote-exec" {
    inline = [
      "chmod +x /tmp/lgtm-stack.sh",
      "sudo bash /tmp/lgtm-stack.sh",
      "rm -f /tmp/lgtm-stack.sh"
    ]
  }

  # ── Pushgateway: receives DORA metrics pushed from GitHub Actions ──────────
  # Installed separately so lgtm-stack.sh does not need modification.
  # Runs after the main stack is up so Prometheus can be reloaded immediately.
  provisioner "file" {
    source      = "../scripts/install-pushgateway.sh"
    destination = "/tmp/install-pushgateway.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "chmod +x /tmp/install-pushgateway.sh",
      "sudo bash /tmp/install-pushgateway.sh",
      "rm -f /tmp/install-pushgateway.sh"
    ]
  }
}

# ── SSM: store both server private IPs so each bootstrap script can find the other ──
# These are plain String (not SecureString) — IPs are not secret.
resource "aws_ssm_parameter" "monitoring_server_ip" {
  name  = "/lgtm/monitoring_server_ip"
  type  = "String"
  value = aws_instance.monitoring.private_ip
}

resource "aws_ssm_parameter" "monitoring_server_public_ip" {
  name  = "/lgtm/monitoring_server_public_ip"
  type  = "String"
  value = aws_eip.monitoring.public_ip
}

resource "aws_ssm_parameter" "app_server_ip" {
  name  = "/lgtm/app_server_ip"
  type  = "String"
  value = aws_instance.app.private_ip
}

# ── IAM: app server reads /lgtm/monitoring_server_ip from SSM ─────────────────
resource "aws_iam_role" "app" {
  name = "lgtm-app-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "app_ssm" {
  name = "lgtm-app-ssm-read"
  role = aws_iam_role.app.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["ssm:GetParameter", "ssm:GetParameters"]
      Resource = "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter/lgtm/*"
    }]
  })
}

resource "aws_iam_instance_profile" "app" {
  name = "lgtm-app-profile"
  role = aws_iam_role.app.name
}

# ── App server security group ──────────────────────────────────────────────────
# Cross-server rule (9100 from monitoring) is added via aws_security_group_rule
# below, after both instances exist.
resource "aws_security_group" "app" {
  name        = "lgtm-app-sg"
  description = "LGTM app server - public fake service + engineer SSH"
  vpc_id      = aws_vpc.monitoring.id

  ingress {
    description = "SSH from engineers"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = var.engineer_ips
  }

  ingress {
    description = "Fake service open to internet"
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "lgtm-app-sg" }
}

# ── App server EC2 instance ────────────────────────────────────────────────────
# t3.micro is sufficient — fake service + node-exporter + otel-collector is light.
# No Elastic IP: the public IP is ephemeral but we use private IPs for all
# inter-server communication so stability doesn't matter here.
resource "aws_instance" "app" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = var.app_instance_type
  key_name                    = aws_key_pair.monitoring.key_name
  subnet_id                   = aws_subnet.monitoring_public.id
  vpc_security_group_ids      = [aws_security_group.app.id]
  iam_instance_profile        = aws_iam_instance_profile.app.name
  associate_public_ip_address = true

  root_block_device {
    volume_type           = "gp3"
    volume_size           = 20
    delete_on_termination = true
  }

  tags = { Name = "lgtm-app" }
}

# ── Cross-server security group rules ─────────────────────────────────────────
# Defined after both instances exist to break the circular dependency.

# Monitoring server: receive OTLP traces from app server (Tempo)
resource "aws_security_group_rule" "monitoring_otlp_grpc" {
  security_group_id = aws_security_group.monitoring.id
  type              = "ingress"
  description       = "OTLP gRPC from app server"
  from_port         = 4317
  to_port           = 4317
  protocol          = "tcp"
  cidr_blocks       = ["${aws_instance.app.private_ip}/32"]
}

# Monitoring server: receive OTLP HTTP from app server (Tempo)
resource "aws_security_group_rule" "monitoring_otlp_http" {
  security_group_id = aws_security_group.monitoring.id
  type              = "ingress"
  description       = "OTLP HTTP from app server"
  from_port         = 4318
  to_port           = 4318
  protocol          = "tcp"
  cidr_blocks       = ["${aws_instance.app.private_ip}/32"]
}

# Monitoring server: receive OTLP logs from app server (Loki)
resource "aws_security_group_rule" "monitoring_loki_otlp" {
  security_group_id = aws_security_group.monitoring.id
  type              = "ingress"
  description       = "Loki OTLP push from app server"
  from_port         = 3100
  to_port           = 3100
  protocol          = "tcp"
  cidr_blocks       = ["${aws_instance.app.private_ip}/32"]
}

# App server: allow Prometheus on monitoring server to scrape node-exporter
resource "aws_security_group_rule" "app_node_exporter" {
  security_group_id = aws_security_group.app.id
  type              = "ingress"
  description       = "Prometheus scraping node-exporter"
  from_port         = 9100
  to_port           = 9100
  protocol          = "tcp"
  cidr_blocks       = ["${aws_instance.monitoring.private_ip}/32"]
}

# App server: allow Prometheus to scrape fake-service /metrics
resource "aws_security_group_rule" "app_fake_service_metrics" {
  security_group_id = aws_security_group.app.id
  type              = "ingress"
  description       = "Prometheus scraping fake-service metrics"
  from_port         = 8080
  to_port           = 8080
  protocol          = "tcp"
  cidr_blocks       = ["${aws_instance.monitoring.private_ip}/32"]
}

# ── Bootstrap: provision the app server ───────────────────────────────────────
# Runs after monitoring_server_ip is in SSM so app-agent.sh can fetch it.
resource "null_resource" "bootstrap_app" {
  triggers = {
    instance_id = aws_instance.app.id
  }

  depends_on = [
    aws_instance.app,
    aws_ssm_parameter.monitoring_server_ip,
  ]

  connection {
    type        = "ssh"
    user        = "ubuntu"
    private_key = file(var.ssh_private_key_path)
    host        = aws_instance.app.public_ip
    timeout     = "10m"
  }

  provisioner "remote-exec" {
    inline = ["cloud-init status --wait || true"]
  }

  provisioner "remote-exec" {
    inline = ["mkdir -p /tmp/lgtm-fake-service"]
  }

  provisioner "file" {
    source      = "../fake-service/app.py"
    destination = "/tmp/lgtm-fake-service/app.py"
  }

  provisioner "file" {
    source      = "../fake-service/requirements.txt"
    destination = "/tmp/lgtm-fake-service/requirements.txt"
  }

  provisioner "file" {
    source      = "../fake-service/chaos.sh"
    destination = "/tmp/lgtm-fake-service/chaos.sh"
  }

  provisioner "file" {
    source      = "../scripts/app-agent.sh"
    destination = "/tmp/app-agent.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "chmod +x /tmp/app-agent.sh",
      "sudo bash /tmp/app-agent.sh",
      "rm -f /tmp/app-agent.sh"
    ]
  }
}

# Update monitoring bootstrap to wait for app_server_ip SSM parameter
# (lgtm-stack.sh reads it to configure Prometheus scrape targets).
# Achieved via depends_on on null_resource.bootstrap below — but since
# that resource already exists, we track the dependency via a separate trigger.
resource "null_resource" "monitoring_ssm_ready" {
  triggers = {
    app_server_ip        = aws_ssm_parameter.app_server_ip.value
    monitoring_server_ip = aws_ssm_parameter.monitoring_server_ip.value
  }
}
