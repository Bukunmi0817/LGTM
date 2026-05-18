#!/usr/bin/env bash
# app-agent.sh — Bootstrap script for the application server.
# Installs: fake-service (Python/Flask), Node Exporter, OTel Collector.
# Fetches MONITORING_SERVER_IP from AWS SSM Parameter Store using the
# instance's IAM role. Falls back to the MONITORING_SERVER_IP env var
# for manual runs on non-AWS machines.
set -euo pipefail

# =============================================================================
# Colour helpers
# =============================================================================
RED='\033[0;31m'; GRN='\033[0;32m'; YEL='\033[1;33m'
BLU='\033[0;34m'; CYN='\033[0;36m'; RST='\033[0m'
BOLD='\033[1m'

info()    { echo -e "${BLU}[INFO]${RST}  $*"; }
ok()      { echo -e "${GRN}[OK]${RST}    $*"; }
warn()    { echo -e "${YEL}[WARN]${RST}  $*"; }
fail()    { echo -e "${RED}[FAIL]${RST}  $*"; ERRORS=$((ERRORS+1)); }
die()     { echo -e "${RED}[FATAL]${RST} $*"; exit 1; }
section() { echo -e "\n${BOLD}${CYN}══ ${1} ══${RST}"; }

ERRORS=0
TMP_DIR=$(mktemp -d /tmp/app-agent.XXXXXX)
trap 'rm -rf "$TMP_DIR"' EXIT

# =============================================================================
# Pre-flight
# =============================================================================
[[ "$EUID" -ne 0 ]] && die "Must be run as root: sudo bash $0"

section "PRE-FLIGHT"
info "OS: $(uname -sr)"
info "Host: $(hostname)"

ARCH=$(uname -m)
case "$ARCH" in
  x86_64)  ARCH_LABEL="amd64" ;;
  aarch64) ARCH_LABEL="arm64" ;;
  *) die "Unsupported architecture: $ARCH" ;;
esac
ok "Architecture: ${ARCH} (${ARCH_LABEL})"

command -v systemctl &>/dev/null || die "systemd not found — this script requires systemd"
ok "systemd: present"

# =============================================================================
# Package dependencies
# =============================================================================
section "INSTALLING DEPENDENCIES"

REQUIRED_PKGS=(wget curl unzip python3 python3-pip python3-venv ufw)
apt-get update -qq
for pkg in "${REQUIRED_PKGS[@]}"; do
  if dpkg -s "$pkg" &>/dev/null; then
    ok "Already installed: ${pkg}"
  else
    apt-get install -y "$pkg"
    ok "Installed: ${pkg}"
  fi
done

# =============================================================================
# AWS CLI v2
# =============================================================================
section "AWS CLI v2"

if ! command -v aws &>/dev/null || ! aws --version 2>&1 | grep -q "aws-cli/2"; then
  info "Installing AWS CLI v2..."
  curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "${TMP_DIR}/awscliv2.zip"
  unzip -q "${TMP_DIR}/awscliv2.zip" -d "${TMP_DIR}/"
  "${TMP_DIR}/aws/install" --update
  ok "AWS CLI v2 installed: $(aws --version 2>&1)"
else
  ok "Already present: $(aws --version 2>&1)"
fi

# =============================================================================
# Fetch MONITORING_SERVER_IP from SSM
# =============================================================================
section "FETCHING CONFIG FROM SSM"

NODE_EXPORTER_VERSION="1.11.1"
OTELCOL_VERSION="0.152.0"

_ssm_get() {
  aws ssm get-parameter --name "$1" --with-decryption \
    --query 'Parameter.Value' --output text 2>/dev/null
}

_wait_for_imds() {
  local i=0
  while (( i < 10 )); do
    aws sts get-caller-identity &>/dev/null 2>&1 && return 0
    (( i++ )) || true
    info "Waiting for instance credentials via IMDS (attempt ${i}/10)..."
    sleep 5
  done
  return 1
}

if _wait_for_imds; then
  MONITORING_SERVER_IP=$(_ssm_get "/lgtm/monitoring_server_ip")
  [[ -z "$MONITORING_SERVER_IP" ]] && die "Failed to fetch /lgtm/monitoring_server_ip from SSM — check instance IAM role"
  ok "Monitoring server IP: ${MONITORING_SERVER_IP}"
else
  info "IMDS not reachable after 50s — falling back to environment variable"
  [[ -z "${MONITORING_SERVER_IP:-}" ]] && die "MONITORING_SERVER_IP not set and SSM not available"
  ok "Monitoring server IP (from env): ${MONITORING_SERVER_IP}"
fi

# =============================================================================
# Users and directories
# =============================================================================
section "USERS AND DIRECTORIES"

if ! id exporter &>/dev/null; then
  useradd -r -s /usr/sbin/nologin -d /nonexistent -M exporter
  ok "User exporter: created"
else
  ok "User exporter: already exists"
fi

if ! id fake-service &>/dev/null; then
  useradd -r -s /usr/sbin/nologin -d /opt/fake-service -m fake-service
  ok "User fake-service: created"
else
  ok "User fake-service: already exists"
fi

for dir in /opt/app-agent/node-exporter /opt/app-agent/otel-collector \
           /etc/otelcol-contrib /var/log/app-agent; do
  mkdir -p "$dir"
  ok "Directory: ${dir}"
done

# =============================================================================
# Fake service
# =============================================================================
section "FAKE SERVICE"

FAKE_SRC="/tmp/lgtm-fake-service"
FAKE_DEST="/opt/fake-service"

[[ ! -d "$FAKE_SRC" ]] && die "Fake service files not found at ${FAKE_SRC} — Terraform should have uploaded them"

mkdir -p "$FAKE_DEST"
cp "${FAKE_SRC}/app.py" "${FAKE_DEST}/"
cp "${FAKE_SRC}/requirements.txt" "${FAKE_DEST}/"
cp "${FAKE_SRC}/chaos.sh" "${FAKE_DEST}/"
chmod +x "${FAKE_DEST}/chaos.sh"
chown -R fake-service:fake-service "$FAKE_DEST"
ok "Fake service files copied to ${FAKE_DEST}"

info "Creating Python virtual environment..."
python3 -m venv "${FAKE_DEST}/venv"
"${FAKE_DEST}/venv/bin/pip" install --quiet --no-cache-dir -r "${FAKE_DEST}/requirements.txt"
chown -R fake-service:fake-service "${FAKE_DEST}/venv"
ok "Python dependencies installed"

cat > /etc/systemd/system/fake-service.service << EOF
[Unit]
Description=LGTM Fake Service — four golden signals demo app
Documentation=https://github.com/your-org/lgtm
After=network.target otelcol-contrib.service
Wants=otelcol-contrib.service

[Service]
Type=simple
User=fake-service
Group=fake-service
WorkingDirectory=${FAKE_DEST}
Environment="OTEL_ENDPOINT=http://localhost:4317"
Environment="SERVICE_NAME=fake-service"

ExecStart=${FAKE_DEST}/venv/bin/python ${FAKE_DEST}/app.py

Restart=on-failure
RestartSec=5s

NoNewPrivileges=yes
PrivateTmp=yes
ProtectHome=yes
ProtectSystem=full
ReadWritePaths=/tmp

MemoryMax=512M
CPUQuota=50%

[Install]
WantedBy=multi-user.target
EOF
ok "fake-service.service: written"

# =============================================================================
# Node Exporter
# =============================================================================
section "NODE EXPORTER ${NODE_EXPORTER_VERSION}"

NE_TARBALL="${TMP_DIR}/node_exporter.tar.gz"
NE_URL="https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VERSION}/node_exporter-${NODE_EXPORTER_VERSION}.linux-${ARCH_LABEL}.tar.gz"

info "Downloading Node Exporter ${NODE_EXPORTER_VERSION}..."
curl -fsSL "$NE_URL" -o "$NE_TARBALL"
tar xzf "$NE_TARBALL" -C "${TMP_DIR}/"
cp "${TMP_DIR}/node_exporter-${NODE_EXPORTER_VERSION}.linux-${ARCH_LABEL}/node_exporter" \
   /opt/app-agent/node-exporter/node_exporter
chown root:root /opt/app-agent/node-exporter/node_exporter
chmod 755 /opt/app-agent/node-exporter/node_exporter
ln -sf /opt/app-agent/node-exporter/node_exporter /usr/local/bin/node_exporter
ok "Node Exporter ${NODE_EXPORTER_VERSION} installed"

cat > /etc/systemd/system/node-exporter.service << 'EOF'
[Unit]
Description=Prometheus Node Exporter
After=network.target

[Service]
Type=simple
User=exporter
Group=exporter

# Listens on 0.0.0.0:9100 so the monitoring server can scrape from outside.
# The security group restricts inbound 9100 to the monitoring server IP only.
ExecStart=/usr/local/bin/node_exporter \
  --path.procfs=/proc \
  --path.sysfs=/sys \
  --path.rootfs=/ \
  --collector.filesystem.mount-points-exclude=^/(sys|proc|dev|host|etc)($$|/) \
  --web.listen-address=0.0.0.0:9100

Restart=on-failure
RestartSec=5s

NoNewPrivileges=yes
PrivateTmp=yes
ProtectHome=yes
ProtectSystem=full
ReadOnlyPaths=/proc /sys /

LimitNOFILE=8192
MemoryMax=256M
CPUQuota=20%

[Install]
WantedBy=multi-user.target
EOF
ok "node-exporter.service: written"

# =============================================================================
# OTel Collector (otelcol-contrib)
# =============================================================================
section "OTEL COLLECTOR ${OTELCOL_VERSION}"

OTEL_DEB="${TMP_DIR}/otelcol-contrib.deb"
OTEL_URL="https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/v${OTELCOL_VERSION}/otelcol-contrib_${OTELCOL_VERSION}_linux_amd64.deb"

info "Downloading OTel Collector ${OTELCOL_VERSION}..."
curl -fsSL "$OTEL_URL" -o "$OTEL_DEB"
dpkg -i "$OTEL_DEB"
systemctl disable --now otelcol-contrib 2>/dev/null || true
ok "OTel Collector ${OTELCOL_VERSION} installed (default unit disabled)"

# Agent config: receive OTLP locally, forward to monitoring server
cat > /etc/otelcol-contrib/config.yaml << EOF
extensions:
  health_check:
    endpoint: "127.0.0.1:13133"

receivers:
  otlp:
    protocols:
      grpc:
        endpoint: "127.0.0.1:4317"
      http:
        endpoint: "127.0.0.1:4318"

processors:
  batch:
    timeout: 1s
    send_batch_size: 1024
  memory_limiter:
    check_interval: 1s
    limit_mib: 256
    spike_limit_mib: 64
  resource:
    attributes:
      - action: insert
        key: environment
        value: "production"

exporters:
  # Traces → Tempo on monitoring server
  otlp/tempo:
    endpoint: "${MONITORING_SERVER_IP}:4317"
    tls:
      insecure: true

  # Logs → Loki's native OTLP endpoint on monitoring server
  otlphttp/loki:
    endpoint: "http://${MONITORING_SERVER_IP}:3100/otlp"
    tls:
      insecure: true

  debug:
    verbosity: basic

service:
  extensions: [health_check]
  pipelines:
    traces:
      receivers:  [otlp]
      processors: [memory_limiter, batch, resource]
      exporters:  [otlp/tempo]

    logs:
      receivers:  [otlp]
      processors: [memory_limiter, batch, resource]
      exporters:  [otlphttp/loki]
EOF
ok "OTel Collector config written (exporting to ${MONITORING_SERVER_IP})"

# Override the default unit to use our config path
mkdir -p /etc/systemd/system/otelcol-contrib.service.d
cat > /etc/systemd/system/otelcol-contrib.service.d/override.conf << 'EOF'
[Service]
ExecStart=
ExecStart=/usr/bin/otelcol-contrib --config=/etc/otelcol-contrib/config.yaml
Restart=on-failure
RestartSec=5s
MemoryMax=512M
CPUQuota=30%
EOF
ok "otelcol-contrib.service: override written"

# =============================================================================
# Firewall (ufw)
# =============================================================================
section "FIREWALL"

ufw --force reset
# SSH: open to anyone (engineers connect to this server)
ufw allow 22/tcp comment "SSH"
# Fake service: open to anyone (public demo endpoint)
ufw allow 8080/tcp comment "Fake service"
# Node Exporter: monitoring server only
ufw allow from "${MONITORING_SERVER_IP}" to any port 9100 proto tcp comment "Prometheus scraping"
# OTel ports are localhost-only (no inbound rule needed — app sends locally)
ufw --force enable
ok "ufw rules applied (9100 restricted to ${MONITORING_SERVER_IP})"

# =============================================================================
# Start and verify
# =============================================================================
section "STARTING SERVICES"

_start_verify() {
  local unit="$1" url="$2" timeout="${3:-30}"
  info "Starting ${unit}..."
  systemctl daemon-reload
  systemctl enable "$unit"
  systemctl restart "$unit"

  local elapsed=0
  while (( elapsed < timeout )); do
    if curl -sf "$url" -o /dev/null 2>/dev/null; then
      ok "${unit}: healthy (${elapsed}s)"
      return 0
    fi
    sleep 2
    (( elapsed+=2 )) || true
  done
  fail "${unit}: did not become healthy within ${timeout}s"
  journalctl -u "$unit" -n 20 --no-pager || true
  return 1
}

_start_verify "otelcol-contrib.service" "http://127.0.0.1:13133/" 45
_start_verify "node-exporter.service"   "http://127.0.0.1:9100/metrics" 45
_start_verify "fake-service.service"    "http://127.0.0.1:8080/health" 60

# =============================================================================
# Final summary
# =============================================================================
section "APP AGENT COMPLETE"

echo ""
echo "  Fake service   → http://$(curl -s https://checkip.amazonaws.com 2>/dev/null || echo '<public-ip>'):8080"
echo "  Health check   → /health"
echo "  Metrics (Prom) → /metrics"
echo "  Chaos script   → ${FAKE_DEST}/chaos.sh [error-burst|latency-spike|normal|check]"
echo ""
echo "  Telemetry is flowing to monitoring server at ${MONITORING_SERVER_IP}"
echo "  Prometheus will scrape node-exporter at $(hostname -I | awk '{print $1}'):9100"
echo ""

[[ "$ERRORS" -gt 0 ]] && die "App agent completed with ${ERRORS} error(s) — check output above."
ok "All services running. App server is ready."
