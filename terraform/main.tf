locals {
  domain      = "${var.duckdns_subdomain}.duckdns.org"
  grafana_url = "http://${var.server_ip}:3000"
}

resource "null_resource" "observability_stack" {

  # If any of these values change, Terraform re-runs the provisioners
  triggers = {
    server_ip     = var.server_ip
    slack_channel = var.slack_channel
  }

  # ----------------------------------------------------------------
  # SSH connection — how Terraform talks to your server
  # ----------------------------------------------------------------
  connection {
    type        = "ssh"
    user        = var.ssh_user
    private_key = file(var.ssh_key_path)
    host        = var.server_ip
    timeout     = "5m"
  }

  # ----------------------------------------------------------------
  # Step 1: Create staging directory on the server
  # This is a temporary folder where we upload everything before
  # the install script moves things to their final locations.
  # ----------------------------------------------------------------
  provisioner "remote-exec" {
    inline = [
      "mkdir -p /tmp/obs-setup/configs/prometheus/rules",
      "mkdir -p /tmp/obs-setup/configs/loki",
      "mkdir -p /tmp/obs-setup/configs/tempo",
      "mkdir -p /tmp/obs-setup/configs/alertmanager/templates",
      "mkdir -p /tmp/obs-setup/configs/otel",
      "mkdir -p /tmp/obs-setup/configs/blackbox",
      "mkdir -p /tmp/obs-setup/configs/grafana/provisioning/datasources",
      "mkdir -p /tmp/obs-setup/configs/grafana/provisioning/dashboards",
      "mkdir -p /tmp/obs-setup/configs/grafana/dashboards",
      "mkdir -p /tmp/obs-setup/systemd",
      "mkdir -p /tmp/obs-setup/app",
      "echo 'Staging directory ready'"
    ]
  }

  # ----------------------------------------------------------------
  # Step 2: Upload all config files
  # ----------------------------------------------------------------
  provisioner "file" {
    source      = "../configs/prometheus/prometheus.yml"
    destination = "/tmp/obs-setup/configs/prometheus/prometheus.yml"
  }

  provisioner "file" {
    source      = "../configs/prometheus/rules/"
    destination = "/tmp/obs-setup/configs/prometheus/rules"
  }

  provisioner "file" {
    source      = "../configs/loki/loki-config.yml"
    destination = "/tmp/obs-setup/configs/loki/loki-config.yml"
  }

  provisioner "file" {
    source      = "../configs/tempo/tempo-config.yml"
    destination = "/tmp/obs-setup/configs/tempo/tempo-config.yml"
  }

  provisioner "file" {
    source      = "../configs/alertmanager/alertmanager.yml"
    destination = "/tmp/obs-setup/configs/alertmanager/alertmanager.yml"
  }

  provisioner "file" {
    source      = "../configs/alertmanager/templates/slack.tmpl"
    destination = "/tmp/obs-setup/configs/alertmanager/templates/slack.tmpl"
  }

  provisioner "file" {
    source      = "../configs/otel/otel-collector.yml"
    destination = "/tmp/obs-setup/configs/otel/otel-collector.yml"
  }

  provisioner "file" {
    source      = "../configs/blackbox/blackbox.yml"
    destination = "/tmp/obs-setup/configs/blackbox/blackbox.yml"
  }

  provisioner "file" {
    source      = "../configs/grafana/provisioning/datasources/datasources.yml"
    destination = "/tmp/obs-setup/configs/grafana/provisioning/datasources/datasources.yml"
  }

  provisioner "file" {
    source      = "../configs/grafana/provisioning/dashboards/dashboards.yml"
    destination = "/tmp/obs-setup/configs/grafana/provisioning/dashboards/dashboards.yml"
  }

  provisioner "file" {
    source      = "../configs/grafana/dashboards/"
    destination = "/tmp/obs-setup/configs/grafana/dashboards"
  }

  # ----------------------------------------------------------------
  # Step 3: Upload systemd service files
  # ----------------------------------------------------------------
  provisioner "file" {
    source      = "../systemd/"
    destination = "/tmp/obs-setup/systemd"
  }

  # ----------------------------------------------------------------
  # Step 4: Upload the sample instrumented app
  # ----------------------------------------------------------------
  provisioner "file" {
    source      = "../app/"
    destination = "/tmp/obs-setup/app"
  }

  # ----------------------------------------------------------------
  # Step 5: Upload and run the install script
  # ----------------------------------------------------------------
  provisioner "file" {
    source      = "../scripts/install.sh"
    destination = "/tmp/obs-setup/install.sh"
  }

  provisioner "remote-exec" {
    inline = [
      # Write secrets into environment variables the install script reads
      "echo 'SLACK_WEBHOOK_URL=${var.slack_webhook_url}' > /tmp/obs-setup/.env",
      "echo 'SLACK_CHANNEL=${var.slack_channel}' >> /tmp/obs-setup/.env",
      "echo 'GRAFANA_PASSWORD=${var.grafana_admin_password}' >> /tmp/obs-setup/.env",
      "echo 'DUCKDNS_TOKEN=${var.duckdns_token}' >> /tmp/obs-setup/.env",
      "echo 'DUCKDNS_SUBDOMAIN=${var.duckdns_subdomain}' >> /tmp/obs-setup/.env",
      "echo 'METRICS_RETENTION=${var.metrics_retention}' >> /tmp/obs-setup/.env",
      "echo 'LOGS_RETENTION=${var.logs_retention}' >> /tmp/obs-setup/.env",
      "echo 'SERVER_IP=${var.server_ip}' >> /tmp/obs-setup/.env",

      # Make the install script executable and run it with sudo
      "chmod +x /tmp/obs-setup/install.sh",
      "sudo /tmp/obs-setup/install.sh",
    ]
  }
}
