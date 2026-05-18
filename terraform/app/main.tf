locals {
  app_user_data = base64encode(file("${path.module}/user_data_app.sh"))
}

resource "aws_instance" "app" {
  ami                    = var.instance_ami
  instance_type          = var.app_instance_type
  subnet_id              = var.app_subnet_id
  vpc_security_group_ids = [var.app_sg_id]
  iam_instance_profile   = var.ec2_profile_name

  user_data = local.app_user_data

  associate_public_ip_address = true

  root_block_device {
    volume_size           = 50
    volume_type           = "gp3"
    delete_on_termination = true
  }

  tags = {
    Name        = "${var.project_name}-app-server"
    Environment = var.environment
    Type        = "application"
  }
}

# Elastic IP for app server
resource "aws_eip" "app_eip" {
  instance = aws_instance.app.id
  domain   = "vpc"

  tags = {
    Name        = "${var.project_name}-app-eip"
    Environment = var.environment
  }
}
