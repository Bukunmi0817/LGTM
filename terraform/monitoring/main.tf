# User data script to install monitoring stack
locals {
  monitoring_user_data = base64encode(templatefile("${path.module}/user_data_monitoring.sh", {
    app_server_ip = var.app_server_private_ip
  }))
}

# Create monitoring server
resource "aws_instance" "monitoring" {
  ami                    = var.instance_ami
  instance_type          = var.monitoring_instance_type
  subnet_id              = var.monitoring_subnet_id
  vpc_security_group_ids = [var.monitoring_sg_id]
  iam_instance_profile   = var.ec2_profile_name
  
  user_data = local.monitoring_user_data

  associate_public_ip_address = true

  root_block_device {
    volume_size           = 100
    volume_type           = "gp3"
    delete_on_termination = true
  }

  tags = {
    Name        = "${var.project_name}-monitoring-server"
    Environment = var.environment
    Type        = "monitoring"
  }

  depends_on = [var.app_instance_id]
}

# Elastic IP for monitoring server
resource "aws_eip" "monitoring_eip" {
  instance = aws_instance.monitoring.id
  domain   = "vpc"

  tags = {
    Name        = "${var.project_name}-monitoring-eip"
    Environment = var.environment
  }
}
