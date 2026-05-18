#!/bin/bash
set -e

echo "=========================================="
echo "Installing Monitoring Stack"
echo "=========================================="

# Update system
apt-get update
apt-get upgrade -y
apt-get install -y curl wget git docker.io docker-compose

# Start Docker
systemctl start docker
systemctl enable docker
usermod -aG docker ubuntu

# Create directories
mkdir -p /opt/monitoring/{prometheus,alertmanager,loki,tempo,grafana,otel}
cd /opt/monitoring

# Create Prometheus config
cat > prometheus.yml << 'PROMEOF'
global:
  scrape_interval: 15s
  evaluation_interval: 15s

scrape_configs:
  - job_name: 'app-server'
    static_configs:
      - targets: ['${app_server_ip}:9100']
        labels:
          instance: 'app-server'

  - job_name: 'monitoring-server'
    static_configs:
      - targets: ['localhost:9100']
        labels:
          instance: 'monitoring-server'
PROMEOF

# Create docker-compose file
cat > docker-compose.yml << 'COMPOSEEOF'
version: '3.8'

services:
  prometheus:
    image: prom/prometheus:latest
    ports:
      - "9090:9090"
    volumes:
      - ./prometheus.yml:/etc/prometheus/prometheus.yml
      - prometheus_data:/prometheus
    command:
      - '--config.file=/etc/prometheus/prometheus.yml'
      - '--storage.tsdb.path=/prometheus'
    restart: always

  grafana:
    image: grafana/grafana:latest
    ports:
      - "3000:3000"
    environment:
      - GF_SECURITY_ADMIN_PASSWORD=admin
    volumes:
      - grafana_data:/var/lib/grafana
    restart: always

  node-exporter:
    image: prom/node-exporter:latest
    ports:
      - "9100:9100"
    volumes:
      - /proc:/host/proc:ro
      - /sys:/host/sys:ro
      - /:/rootfs:ro
    command:
      - '--path.procfs=/host/proc'
      - '--path.sysfs=/host/sys'
    restart: always

volumes:
  prometheus_data:
  grafana_data:

networks:
  default:
    driver: bridge
COMPOSEEOF

# Start monitoring stack
docker-compose up -d

echo "=========================================="
echo "Monitoring Stack Started!"
echo "=========================================="
echo "Grafana: http://$(hostname -I | awk '{print $1}'):3000 (admin/admin)"
echo "Prometheus: http://$(hostname -I | awk '{print $1}'):9090"
