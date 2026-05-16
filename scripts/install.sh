#!/bin/bash
# =============================================================
# LGTM Observability Stack — systemd installer
# Runs on the server as root (via sudo)
# =============================================================
set -e  # stop immediately if any command fails

# Load secrets that Terraform wrote into .env
source /tmp/obs-setup/.env

STAGING="/tmp/obs-setup"
GREEN='\033[0;32m'
NC='\033[0m'
log() { echo -e "${GREEN}[INSTALL]${NC} $1"; }

# =============================================================
# 1. System packages
# =============================================================
log "Updating system and installing dependencies..."
apt-get update -y
apt-get install -y \
  wget curl unzip \
  python3 python3-pip python3-venv \
  apt-transport-https software-properties-common \
  adduser libfontconfig1

# =============================================================
# 2. NODE EXPORTER
# Collects host metrics: CPU, RAM, disk, network
# Runs as its own unprivileged user for security
# =============================================================
log "Installing Node Exporter..."

# Create a system user that cannot log in (security best practice)
useradd --no-create-home --shell /bin/false node_exporter 2>/dev/null || true

# Download the binary from GitHub releases
cd /tmp
wget -q https://github.com/prometheus/node_exporter/releases/download/v1.7.0/node_exporter-1.7.0.linux-amd64.tar.gz
tar xzf node_exporter-1.7.0.linux-amd64.tar.gz

# Move binary to /usr/local/bin — the standard location for manually installed binaries
cp node_exporter-1.7.0.linux-amd64/node_exporter /usr/local/bin/
chown node_exporter:node_exporter /usr/local/bin/node_exporter
rm -rf node_exporter-1.7.0.linux-amd64*

# Install the systemd service file
cp $STAGING/systemd/node_exporter.service /etc/systemd/system/

log "Node Exporter installed"

# =============================================================
# 3. BLACKBOX EXPORTER
# Probes HTTP endpoints and SSL certificates from the outside
# =============================================================
log "Installing Blackbox Exporter..."

useradd --no-create-home --shell /bin/false blackbox 2>/dev/null || true
mkdir -p /etc/blackbox

cd /tmp
wget -q https://github.com/prometheus/blackbox_exporter/releases/download/v0.25.0/blackbox_exporter-0.25.0.linux-amd64.tar.gz
tar xzf blackbox_exporter-0.25.0.linux-amd64.tar.gz
cp blackbox_exporter-0.25.0.linux-amd64/blackbox_exporter /usr/local/bin/
chown blackbox:blackbox /usr/local/bin/blackbox_exporter
rm -rf blackbox_exporter-0.25.0.linux-amd64*

# Upload config
cp $STAGING/configs/blackbox/blackbox.yml /etc/blackbox/
chown -R blackbox:blackbox /etc/blackbox

cp $STAGING/systemd/blackbox_exporter.service /etc/systemd/system/

log "Blackbox Exporter installed"

# =============================================================
# 4. ALERTMANAGER
# Receives alerts from Prometheus, groups them, sends to Slack
# Must start before Prometheus so Prometheus can connect to it
# =============================================================
log "Installing Alertmanager..."

useradd --no-create-home --shell /bin/false alertmanager 2>/dev/null || true
mkdir -p /etc/alertmanager/templates
mkdir -p /var/lib/alertmanager

cd /tmp
wget -q https://github.com/prometheus/alertmanager/releases/download/v0.27.0/alertmanager-0.27.0.linux-amd64.tar.gz
tar xzf alertmanager-0.27.0.linux-amd64.tar.gz
cp alertmanager-0.27.0.linux-amd64/alertmanager /usr/local/bin/
cp alertmanager-0.27.0.linux-amd64/amtool /usr/local/bin/
chown alertmanager:alertmanager /usr/local/bin/alertmanager /usr/local/bin/amtool
rm -rf alertmanager-0.27.0.linux-amd64*

# Inject Slack webhook into alertmanager config
sed -i "s|SLACK_WEBHOOK_PLACEHOLDER|${SLACK_WEBHOOK_URL}|g" $STAGING/configs/alertmanager/alertmanager.yml
sed -i "s|SLACK_CHANNEL_PLACEHOLDER|${SLACK_CHANNEL}|g" $STAGING/configs/alertmanager/alertmanager.yml

cp $STAGING/configs/alertmanager/alertmanager.yml /etc/alertmanager/
cp $STAGING/configs/alertmanager/templates/slack.tmpl /etc/alertmanager/templates/
chown -R alertmanager:alertmanager /etc/alertmanager /var/lib/alertmanager

cp $STAGING/systemd/alertmanager.service /etc/systemd/system/

log "Alertmanager installed"

# =============================================================
# 5. PROMETHEUS
# Scrapes metrics from all services, evaluates alert rules
# =============================================================
log "Installing Prometheus..."

useradd --no-create-home --shell /bin/false prometheus 2>/dev/null || true
mkdir -p /etc/prometheus/rules
mkdir -p /var/lib/prometheus/data

cd /tmp
wget -q https://github.com/prometheus/prometheus/releases/download/v2.51.0/prometheus-2.51.0.linux-amd64.tar.gz
tar xzf prometheus-2.51.0.linux-amd64.tar.gz
cp prometheus-2.51.0.linux-amd64/prometheus /usr/local/bin/
cp prometheus-2.51.0.linux-amd64/promtool /usr/local/bin/
chown prometheus:prometheus /usr/local/bin/prometheus /usr/local/bin/promtool
rm -rf prometheus-2.51.0.linux-amd64*

# Inject retention period into prometheus service
sed -i "s|METRICS_RETENTION_PLACEHOLDER|${METRICS_RETENTION}|g" $STAGING/systemd/prometheus.service

cp $STAGING/configs/prometheus/prometheus.yml /etc/prometheus/
cp $STAGING/configs/prometheus/rules/*.yml /etc/prometheus/rules/
chown -R prometheus:prometheus /etc/prometheus /var/lib/prometheus

cp $STAGING/systemd/prometheus.service /etc/systemd/system/

log "Prometheus installed"

# =============================================================
# 6. LOKI
# Stores and indexes logs — queryable via LogQL in Grafana
# =============================================================
log "Installing Loki..."

useradd --no-create-home --shell /bin/false loki 2>/dev/null || true
mkdir -p /etc/loki
mkdir -p /var/lib/loki/{chunks,rules,boltdb-compactor}

cd /tmp
wget -q https://github.com/grafana/loki/releases/download/v2.9.7/loki-linux-amd64.zip
unzip -q loki-linux-amd64.zip
chmod +x loki-linux-amd64
cp loki-linux-amd64 /usr/local/bin/loki
chown loki:loki /usr/local/bin/loki
rm -f loki-linux-amd64*

cp $STAGING/configs/loki/loki-config.yml /etc/loki/
chown -R loki:loki /etc/loki /var/lib/loki

cp $STAGING/systemd/loki.service /etc/systemd/system/

log "Loki installed"

# =============================================================
# 7. TEMPO
# Stores distributed traces — queryable via TraceQL in Grafana
# =============================================================
log "Installing Tempo..."

useradd --no-create-home --shell /bin/false tempo 2>/dev/null || true
mkdir -p /etc/tempo
mkdir -p /var/lib/tempo/{wal,blocks,generator}

cd /tmp
wget -q https://github.com/grafana/tempo/releases/download/v2.4.1/tempo_2.4.1_linux_amd64.tar.gz
tar xzf tempo_2.4.1_linux_amd64.tar.gz
cp tempo /usr/local/bin/tempo
chown tempo:tempo /usr/local/bin/tempo
rm -f tempo tempo_2.4.1_linux_amd64.tar.gz

cp $STAGING/configs/tempo/tempo-config.yml /etc/tempo/
chown -R tempo:tempo /etc/tempo /var/lib/tempo

cp $STAGING/systemd/tempo.service /etc/systemd/system/

log "Tempo installed"

# =============================================================
# 8. OPENTELEMETRY COLLECTOR
# Receives logs and traces from the app, forwards to Loki + Tempo
# =============================================================
log "Installing OpenTelemetry Collector..."

useradd --no-create-home --shell /bin/false otel 2>/dev/null || true
mkdir -p /etc/otel

cd /tmp
wget -q https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/v0.99.0/otelcol-contrib_0.99.0_linux_amd64.tar.gz
tar xzf otelcol-contrib_0.99.0_linux_amd64.tar.gz
cp otelcol-contrib /usr/local/bin/
chown otel:otel /usr/local/bin/otelcol-contrib
rm -f otelcol-contrib otelcol-contrib_0.99.0_linux_amd64.tar.gz

cp $STAGING/configs/otel/otel-collector.yml /etc/otel/
chown -R otel:otel /etc/otel

cp $STAGING/systemd/otel-collector.service /etc/systemd/system/

log "OTel Collector installed"

# =============================================================
# 9. GRAFANA
# The unified UI — shows metrics, logs, and traces together
# Installed via the official apt repository (cleanest method)
# =============================================================
log "Installing Grafana..."

# Add Grafana's official apt repo and GPG key
wget -q -O /usr/share/keyrings/grafana.key https://apt.grafana.com/gpg.key
echo "deb [signed-by=/usr/share/keyrings/grafana.key] https://apt.grafana.com stable main" \
  > /etc/apt/sources.list.d/grafana.list
apt-get update -y
apt-get install -y grafana=10.4.1

# Set admin password
sed -i "s|;admin_password = admin|admin_password = ${GRAFANA_PASSWORD}|g" /etc/grafana/grafana.ini

# Copy provisioning files (datasources and dashboard configs)
cp -r $STAGING/configs/grafana/provisioning/* /etc/grafana/provisioning/

# Create dashboard directory and copy dashboard JSON files
mkdir -p /var/lib/grafana/dashboards
cp -r $STAGING/configs/grafana/dashboards/* /var/lib/grafana/dashboards/ 2>/dev/null || true
chown -R grafana:grafana /var/lib/grafana /etc/grafana/provisioning

log "Grafana installed"

# =============================================================
# 10. SAMPLE INSTRUMENTED APP
# A Python FastAPI service that emits traces to Tempo
# Satisfies the "instrument at least one service" requirement
# =============================================================
log "Installing Sample App..."

# Create app directory
mkdir -p /opt/sample-app

# Copy app files
cp $STAGING/app/main.py /opt/sample-app/
cp $STAGING/app/requirements.txt /opt/sample-app/

# Create Python virtual environment and install dependencies
python3 -m venv /opt/sample-app/venv
/opt/sample-app/venv/bin/pip install -q -r /opt/sample-app/requirements.txt

# Create app user
useradd --no-create-home --shell /bin/false sampleapp 2>/dev/null || true
chown -R sampleapp:sampleapp /opt/sample-app

cp $STAGING/systemd/sample-app.service /etc/systemd/system/

log "Sample App installed"

# =============================================================
# 11. START ALL SERVICES
# systemctl daemon-reload tells systemd to read all the new
# .service files we just copied into /etc/systemd/system/
# =============================================================
log "Starting all services..."

systemctl daemon-reload

SERVICES=(
  node_exporter
  blackbox_exporter
  alertmanager
  prometheus
  loki
  tempo
  otel-collector
  grafana-server
  sample-app
)

for service in "${SERVICES[@]}"; do
  systemctl enable "$service"
  systemctl restart "$service"
  sleep 2
  if systemctl is-active --quiet "$service"; then
    log "$service is running"
  else
    echo "WARNING: $service may not have started — check: sudo journalctl -u $service -n 20"
  fi
done

# =============================================================
# 12. CLEANUP
# =============================================================
rm -rf /tmp/obs-setup
rm -rf /tmp/*.tar.gz /tmp/*.zip

log "============================================"
log "Installation complete!"
log "Grafana:      http://${SERVER_IP}:3000"
log "Prometheus:   http://${SERVER_IP}:9090"
log "Alertmanager: http://${SERVER_IP}:9093"
log "Loki:         http://${SERVER_IP}:3100"
log "Tempo:        http://${SERVER_IP}:3200"
log "Sample App:   http://${SERVER_IP}:8000"
log "============================================"
