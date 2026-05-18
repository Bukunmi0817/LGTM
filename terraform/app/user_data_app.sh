#!/bin/bash
set -e

echo "=========================================="
echo "Installing Node Exporter on App Server"
echo "=========================================="

# Update system
apt-get update
apt-get upgrade -y
apt-get install -y curl wget git

# Create node-exporter user
useradd --no-create-home --shell /bin/false node_exporter || true

# Download and install Node Exporter
cd /tmp
wget https://github.com/prometheus/node_exporter/releases/download/v1.7.0/node_exporter-1.7.0.linux-amd64.tar.gz
tar xvfz node_exporter-1.7.0.linux-amd64.tar.gz
sudo cp node_exporter-1.7.0.linux-amd64/node_exporter /usr/local/bin/
sudo chown node_exporter:node_exporter /usr/local/bin/node_exporter

# Create systemd service
cat > /etc/systemd/system/node_exporter.service << 'SERVICEEOF'
[Unit]
Description=Node Exporter
After=network.target

[Service]
User=node_exporter
Group=node_exporter
Type=simple
ExecStart=/usr/local/bin/node_exporter \
  --collector.filesystem.mount-points-exclude=^/(sys|proc|dev|host|etc)($$|/) \
  --collector.filesystem.fs-types-exclude=^(autofs|binfmt_misc|bpf|cgroup2?|configfs|debugfs|devpts|devtmpfs|fusectl|hugetlbfs|iso9660|mqueue|nsfs|overlay|proc|procfs|pstore|rpc_pipefs|securityfs|selinuxfs|squashfs|sysfs|tracefs)$$ \
  --web.listen-address=:9100

Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
SERVICEEOF

# Enable and start Node Exporter
systemctl daemon-reload
systemctl enable node_exporter
systemctl start node_exporter

# Verify
systemctl status node_exporter

echo "=========================================="
echo "Node Exporter installed successfully!"
echo "=========================================="
echo "Access metrics at: http://$(hostname -I | awk '{print $1}'):9100/metrics"
