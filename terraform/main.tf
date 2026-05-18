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

  # Pushgateway receives DORA metrics pushed from GitHub Actions.
  # GitHub Actions IPs are dynamic — to allow CI pushes, either add
  # GitHub's published IP ranges here or open to 0.0.0.0/0 and rely on
  # a push token for auth. Restricted to engineers for now.
  ingress {
    description = "Pushgateway from engineers"
    from_port   = 9091
    to_port     = 9091
    protocol    = "tcp"
    cidr_blocks = var.engineer_ips
  }

  # OTLP gRPC and HTTP: app server pushes traces and logs to OTel Collector
  ingress {
    description = "OTLP gRPC from app server"
    from_port   = 4317
    to_port     = 4317
    protocol    = "tcp"
    cidr_blocks = [var.app_server_ip]
  }

  ingress {
    description = "OTLP HTTP from app server"
    from_port   = 4318
    to_port     = 4318
    protocol    = "tcp"
    cidr_blocks = [var.app_server_ip]
  }

  # Loki push API: used if the app server runs Promtail or direct Loki push
  ingress {
    description = "Loki push from app server"
    from_port   = 3100
    to_port     = 3100
    protocol    = "tcp"
    cidr_blocks = [var.app_server_ip]
  }

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

  depends_on = [aws_eip_association.monitoring]

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
