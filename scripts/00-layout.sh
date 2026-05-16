#!/usr/bin/env bash
# =============================================================================
# LGTM Stack — Phase 0 (Pre-flight) + Phase 1 (Directory & File Layout)
# Run as root: sudo bash 00-preflight-and-layout.sh
# =============================================================================

set -euo pipefail
IFS=$'\n\t'

# Colour codes
RED='\033[0;31m'
YEL='\033[0;33m'
GRN='\033[0;32m'
BLU='\033[0;34m'
CYN='\033[0;36m'
BLD='\033[1m'
RST='\033[0m'

# Logging helpers
info()    { echo -e "${BLU}[INFO]${RST}  $*"; }
ok()      { echo -e "${GRN}[OK]${RST}    $*"; }
warn()    { echo -e "${YEL}[WARN]${RST}  $*"; }
fail()    { echo -e "${RED}[FAIL]${RST}  $*"; ERRORS=$((ERRORS + 1)); }
section() { echo -e "\n${BLD}${CYN}══ $* ══${RST}"; }
die()     { echo -e "${RED}[FATAL]${RST} $*"; exit 1; }

ERRORS=0
WARNINGS=0

# Must be root
[[ "$EUID" -ne 0 ]] && die "This script must be run as root. Use: sudo bash $0"

# Service definitions
# Format: "username:group:description"
SERVICES=(
  "prometheus:prometheus:Prometheus metrics server"
  "loki:loki:Loki log aggregation"
  "tempo:tempo:Tempo distributed tracing"
  "grafana:grafana:Grafana observability frontend"
  "alertmanager:alertmanager:Alertmanager alert routing"
)

# Services that share a common user (no dedicated user needed)
# node-exporter, blackbox-exporter, otel-collector run as nobody or their own
EXPORTER_SERVICES=(
  "node-exporter"
  "blackbox-exporter"
  "otel-collector"
)

# Directory definitions
# Binary directories
BIN_DIRS=(
  /opt/lgtm/prometheus
  /opt/lgtm/loki
  /opt/lgtm/tempo
  /opt/lgtm/grafana
  /opt/lgtm/alertmanager
  /opt/lgtm/node-exporter
  /opt/lgtm/blackbox-exporter
  /opt/lgtm/otel-collector
)

# Config directories
CONFIG_DIRS=(
  /etc/lgtm/prometheus
  /etc/lgtm/prometheus/rules

  /etc/lgtm/loki
  /etc/lgtm/tempo

  # Grafana: all provisioning subdirs must exist before grafana starts.
  # grafana.ini paths.provisioning will point to /etc/lgtm/grafana/provisioning.
  # Without these dirs, Grafana skips provisioning silently — no error, just
  # empty datasources and no dashboards loaded.
  /etc/lgtm/grafana
  /etc/lgtm/grafana/provisioning
  /etc/lgtm/grafana/provisioning/datasources
  /etc/lgtm/grafana/provisioning/dashboards
  /etc/lgtm/grafana/provisioning/alerting
  /etc/lgtm/grafana/provisioning/plugins

  # Dashboard JSON/YAML files live here (separate from the provider config)
  # Organised by WHAT THE DASHBOARD ANSWERS, not which exporter feeds it data
  #
  # Why this matters: golden signals and HTTP error dashboards are cross-service
  # — they pull from Prometheus, Loki, and fake-service simultaneously
  # Putting them under node-exporter/ or blackbox/ would be semantically wrong
  # and would confuse anyone navigating the repo or the Grafana UI
  #
  # Four groups map to four audiences:
  #   infrastructure/  → ops    "Is the machine healthy?"
  #   reliability/     → SRE    "Is the service reliable?" (we will keep golden signals here)
  #   delivery/        → leads  "Are we shipping well?"
  #   observability/   → anyone "Why is it broken?" (think of it as the drill-down dashboard)
  /etc/lgtm/grafana/dashboards
  /etc/lgtm/grafana/dashboards/infrastructure
  /etc/lgtm/grafana/dashboards/reliability
  /etc/lgtm/grafana/dashboards/delivery
  /etc/lgtm/grafana/dashboards/observability

  /etc/lgtm/alertmanager
  /etc/lgtm/alertmanager/templates
  /etc/lgtm/otel-collector
  /etc/lgtm/blackbox-exporter
)

# Data directories (persistent state)
DATA_DIRS=(
  /var/lib/lgtm/prometheus
  /var/lib/lgtm/loki
  /var/lib/lgtm/loki/chunks
  /var/lib/lgtm/loki/rules
  /var/lib/lgtm/loki/retention
  /var/lib/lgtm/tempo
  /var/lib/lgtm/tempo/traces
  /var/lib/lgtm/tempo/wal
  /var/lib/lgtm/grafana
)

# Log directory
LOG_DIR=/var/log/lgtm

# systemd unit file drop-in location
SYSTEMD_DIR=/etc/systemd/system

# ═════════════════════════════════════════════════════════════════════════════
# PHASE 0 — PRE-FLIGHT CHECKS
# ═════════════════════════════════════════════════════════════════════════════

section "PHASE 0 — PRE-FLIGHT CHECKS"

# 0.1 OS Detection
info "Detecting operating system..."
if [[ -f /etc/os-release ]]; then
  source /etc/os-release
  ok "OS: ${PRETTY_NAME}"
  case "$ID" in
    ubuntu|debian) ok "Supported distro: $ID" ;;
    rhel|centos|fedora|rocky|almalinux) warn "RHEL-family detected — package manager commands may need adjustment" ; WARNINGS=$((WARNINGS+1)) ;;
    *) warn "Unrecognised distro: $ID — proceeding but verify package names manually" ; WARNINGS=$((WARNINGS+1)) ;;
  esac
else
  fail "/etc/os-release not found — cannot detect OS"
fi

# 0.2 Architecture
info "Checking CPU architecture..."
ARCH=$(uname -m)
case "$ARCH" in
  x86_64)  GOARCH="amd64" ; ok "Architecture: x86_64 (amd64)" ;;
  aarch64) GOARCH="arm64" ; ok "Architecture: aarch64 (arm64)" ;;
  armv7l)  GOARCH="armv7" ; warn "armv7 — some LGTM components may not have official binaries" ; WARNINGS=$((WARNINGS+1)) ;;
  *) die "Unsupported architecture: $ARCH" ;;
esac
# Export for use in later phases
mkdir -p /etc/lgtm
touch /etc/lgtm/.arch
echo "GOARCH=${GOARCH}" > /etc/lgtm/.arch
info "Architecture saved to /etc/lgtm/.arch for use in Phase 2"

# 0.3 systemd version
info "Checking systemd version..."
if command -v systemctl &>/dev/null; then
  SYSTEMD_VER=$(systemctl --version | awk 'NR==1{print $2}')
  if [[ "$SYSTEMD_VER" -ge 232 ]]; then
    ok "systemd version: ${SYSTEMD_VER} (>= 232 required)"
  else
    fail "systemd version ${SYSTEMD_VER} is too old — need >= 232 for PrivateTmp, ProtectSystem, DynamicUser"
  fi
else
  die "systemd not found — this stack requires systemd"
fi

# 0.4 Kernel capability checks
info "Checking kernel capabilities..."

# inotify (used by Loki, Grafana for config watching)
if [[ -d /proc/sys/fs/inotify ]]; then
  ok "inotify: available"
  # Check inotify limits — Loki can be a heavy consumer
  INOTIFY_WATCHES=$(cat /proc/sys/fs/inotify/max_user_watches)
  if [[ "$INOTIFY_WATCHES" -lt 65536 ]]; then
    warn "inotify max_user_watches is ${INOTIFY_WATCHES} — recommend >= 65536 for Loki + Grafana"
    WARNINGS=$((WARNINGS+1))
    echo "fs.inotify.max_user_watches = 65536" >> /etc/sysctl.d/99-lgtm.conf
    info "Queued inotify fix in /etc/sysctl.d/99-lgtm.conf (will apply at end of script)"
  fi
else
  fail "inotify not available — Loki and Grafana config watching will fail"
fi

# mmap support (Tempo WAL, Loki TSDB index)
if grep -q 'mmap' /proc/kallsyms 2>/dev/null || [[ -f /proc/sys/vm/mmap_min_addr ]]; then
  ok "mmap: available"
else
  warn "Cannot confirm mmap availability — check kernel config if Tempo/Loki fail to start"
  WARNINGS=$((WARNINGS+1))
fi

# epoll (required for high-concurrency network I/O — Prometheus, Loki)
if [[ -f /proc/sys/fs/epoll/max_user_watches ]] || grep -q CONFIG_EPOLL=y /boot/config-"$(uname -r)" 2>/dev/null; then
  ok "epoll: available"
else
  warn "Could not confirm epoll — likely fine on modern kernels but worth verifying"
  WARNINGS=$((WARNINGS+1))
fi

# 0.5 Disk space
info "Checking available disk space..."
DATA_PARTITION=$(df /var/lib --output=target 2>/dev/null | tail -1)
AVAIL_KB=$(df /var/lib --output=avail 2>/dev/null | tail -1 | tr -d ' ')
AVAIL_GB=$((AVAIL_KB / 1024 / 1024))

if [[ "$AVAIL_GB" -ge 20 ]]; then
  ok "Disk space: ${AVAIL_GB}GB available on ${DATA_PARTITION} (>= 20GB required)"
elif [[ "$AVAIL_GB" -ge 10 ]]; then
  warn "Disk space: ${AVAIL_GB}GB available — minimum 20GB recommended for 30-day retention. Stack will run but monitor closely."
  WARNINGS=$((WARNINGS+1))
else
  fail "Disk space: only ${AVAIL_GB}GB available on ${DATA_PARTITION} — minimum 10GB required, 20GB strongly recommended"
fi

# 0.6 Required packages
info "Checking and installing required packages..."

REQUIRED_PKGS=(wget curl tar unzip python3 adduser)

if command -v apt-get &>/dev/null; then
  # Debian/Ubuntu
  apt-get update -qq 2>/dev/null
  for pkg in "${REQUIRED_PKGS[@]}"; do
    if dpkg -l "$pkg" 2>/dev/null | grep -q '^ii'; then
      ok "Package ${pkg}: already installed"
    else
      info "Installing ${pkg}..."
      apt-get install -y -qq "$pkg" && ok "Package ${pkg}: installed" || fail "Failed to install ${pkg}"
    fi
  done
elif command -v yum &>/dev/null; then
  # RHEL/CentOS
  for pkg in "${REQUIRED_PKGS[@]}"; do
    if rpm -q "$pkg" &>/dev/null; then
      ok "Package ${pkg}: already installed"
    else
      info "Installing ${pkg}..."
      yum install -y -q "$pkg" && ok "Package ${pkg}: installed" || fail "Failed to install ${pkg}"
    fi
  done
else
  warn "No supported package manager found (apt/yum) — install manually: ${REQUIRED_PKGS[*]}"
  WARNINGS=$((WARNINGS+1))
fi

# 0.7 Port availability
info "Checking that required ports are available..."

declare -A SERVICE_PORTS=(
  [9090]="Prometheus"
  [9093]="Alertmanager"
  [9100]="Node Exporter"
  [9115]="Blackbox Exporter"
  [3000]="Grafana"
  [3100]="Loki"
  [3200]="Tempo HTTP"
  [4317]="OTLP gRPC"
  [4318]="OTLP HTTP"
  [8888]="OTel Collector metrics"
  [8080]="Fake Service"
)

for port in "${!SERVICE_PORTS[@]}"; do
  service="${SERVICE_PORTS[$port]}"
  if ss -tlnp 2>/dev/null | grep -q ":${port} " || \
     netstat -tlnp 2>/dev/null | grep -q ":${port} "; then
    # Find what's using it
    OCCUPANT=$(ss -tlnp 2>/dev/null | grep ":${port} " | awk '{print $NF}' | head -1)
    fail "Port ${port} (${service}) is already in use: ${OCCUPANT}"
  else
    ok "Port ${port} (${service}): available"
  fi
done

# 0.8 Create system users
info "Creating dedicated system users for each service..."

for entry in "${SERVICES[@]}"; do
  IFS=':' read -r username group description <<< "$entry"

  if id "$username" &>/dev/null; then
    ok "User ${username}: already exists"
  else
    useradd \
      --system \
      --no-create-home \
      --shell /usr/sbin/nologin \
      --comment "$description" \
      --user-group \
      "$username"
    ok "User ${username}: created (system user, no shell, no home)"
  fi

  # Lock the account for good measure (system users shouldn't be loginable)
  passwd -l "$username" &>/dev/null || true
done

# node-exporter, blackbox-exporter, otel-collector share a common user
for svc in "${EXPORTER_SERVICES[@]}"; do
  username="${svc//-/_}"   # replace hyphens for valid username
  username="${username:0:16}"  # max username length on Linux
  # Use 'nobody' equivalent — these are low-privilege exporters
  # We'll map them to a shared 'exporter' user
  done

# Create a shared exporter user for node-exporter, blackbox-exporter, otel-collector
if ! id "exporter" &>/dev/null; then
  useradd \
    --system \
    --no-create-home \
    --shell /usr/sbin/nologin \
    --comment "Shared user for LGTM exporters" \
    --user-group \
    "exporter"
  ok "User exporter: created (shared user for node-exporter, blackbox-exporter, otel-collector)"
else
  ok "User exporter: already exists"
fi

# 0.9 OS-level ulimits
info "Configuring OS ulimits for LGTM service users..."

LIMITS_CONF=/etc/security/limits.d/99-lgtm.conf

cat > "$LIMITS_CONF" << 'LIMITS'
# LGTM Stack ulimits
# Prometheus TSDB opens many file descriptors under heavy load.
# Loki mmap requires high nofile. Tempo WAL is write-intensive.
# These values are conservative minimums — increase if you scale.

prometheus       soft    nofile          65536
prometheus       hard    nofile          65536
prometheus       soft    nproc           4096
prometheus       hard    nproc           4096

loki             soft    nofile          65536
loki             hard    nofile          65536
loki             soft    nproc           4096
loki             hard    nproc           4096

tempo            soft    nofile          32768
tempo            hard    nofile          32768
tempo            soft    nproc           4096
tempo            hard    nproc           4096

grafana          soft    nofile          16384
grafana          hard    nofile          16384
grafana          soft    nproc           4096
grafana          hard    nproc           4096

alertmanager     soft    nofile          8192
alertmanager     hard    nofile          8192

exporter         soft    nofile          8192
exporter         hard    nofile          8192
LIMITS

ok "ulimits written to ${LIMITS_CONF}"

# Also set systemd-level limits (these override PAM limits for systemd services)
# We'll bake LimitNOFILE into each unit file in Phase 4 — just noting it here.
info "Note: LimitNOFILE will also be set in each systemd unit file in Phase 4 (systemd ignores /etc/security/limits.d for services)"

# 0.10 Kernel parameters
info "Applying kernel parameter tuning..."

SYSCTL_CONF=/etc/sysctl.d/99-lgtm.conf

cat > "$SYSCTL_CONF" << 'SYSCTL'
# LGTM Stack kernel parameter tuning
#
# vm.max_map_count: Loki and Tempo use mmap extensively for TSDB index and WAL.
# Default is 65530 which is usually fine, but under heavy log ingestion Loki
# can exceed this. Elasticsearch docs recommend 262144 — we use same value.
vm.max_map_count = 262144

# fs.inotify: Grafana watches provisioning dirs, Loki watches rule dirs.
# Default max_user_watches (8192) is too low for a busy observability stack.
fs.inotify.max_user_watches = 65536
fs.inotify.max_user_instances = 512

# net.core: Prometheus and Loki handle many concurrent connections.
# These settings improve TCP backlog handling under load.
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 65535
SYSCTL

# Apply immediately without requiring reboot
sysctl -p "$SYSCTL_CONF" &>/dev/null && ok "Kernel parameters applied from ${SYSCTL_CONF}" || warn "Could not apply sysctl params — will take effect on next boot"

# ═════════════════════════════════════════════════════════════════════════════
# PHASE 1 — DIRECTORY & FILE LAYOUT
# ═════════════════════════════════════════════════════════════════════════════

section "PHASE 1 — DIRECTORY & FILE LAYOUT"

# 1.1 Create /etc/lgtm first (needed for .arch file)
mkdir -p /etc/lgtm
ok "Base config directory /etc/lgtm created"

# Re-save arch info now that /etc/lgtm exists
echo "GOARCH=${GOARCH}" > /etc/lgtm/.arch
echo "ARCH=${ARCH}" >> /etc/lgtm/.arch

# 1.2 Binary directories 
info "Creating binary directories under /opt/lgtm/..."

for dir in "${BIN_DIRS[@]}"; do
  if mkdir -p "$dir"; then
    ok "Created: ${dir}"
  else
    fail "Failed to create: ${dir}"
  fi
  # Binaries are owned by root, readable by all, not writable by service users
  chown root:root "$dir"
  chmod 755 "$dir"
done

# 1.3 Config directories 
info "Creating config directories under /etc/lgtm/..."

for dir in "${CONFIG_DIRS[@]}"; do
  if mkdir -p "$dir"; then
    ok "Created: ${dir}"
  else
    fail "Failed to create: ${dir}"
  fi
done

# Set ownership and permissions on config dirs
# Config dirs: root owns, service user can read (not write — prevents self-modification)
chown -R root:prometheus   /etc/lgtm/prometheus
chown -R root:loki         /etc/lgtm/loki
chown -R root:tempo        /etc/lgtm/tempo
chown -R root:grafana      /etc/lgtm/grafana
chown -R root:alertmanager /etc/lgtm/alertmanager
chown -R root:exporter     /etc/lgtm/otel-collector
chown -R root:exporter     /etc/lgtm/blackbox-exporter

# Directories: root can rwx, group can rx (read configs, traverse dirs)
find /etc/lgtm -type d -exec chmod 750 {} \;
ok "Config directory permissions set (750 — root:group)"

# 1.3b Grafana provisioning — explicit setup 
# This section exists because Grafana provisioning is the most commonly
# misconfigured part of a self-hosted stack. Three things must all be true
# simultaneously or dashboards silently don't load:
#
#   1. The provisioning dirs exist and are readable by the grafana user
#   2. grafana.ini paths.provisioning points at the right parent directory
#   3. The dashboard JSON/YAML files are readable by the grafana user
#
# We handle 1 and 3 here. 2 is handled in Phase 3 (config file generation).

info "Setting up Grafana provisioning directory structure..."

# The provider YAML that tells Grafana where dashboard JSON files live.
# This file is written now so Phase 3 only needs to fill datasources.yml.
# disableDeletion: true — Grafana cannot delete provisioned dashboards via UI.
# allowUiUpdates: false — UI edits are discarded on restart; edit the JSON file.
# This enforces the "dashboards as code" requirement from the project brief.
DASHBOARD_PROVIDER=/etc/lgtm/grafana/provisioning/dashboards/provider.yml
if [[ ! -f "$DASHBOARD_PROVIDER" ]]; then
  cat > "$DASHBOARD_PROVIDER" << 'PROVIDER'
apiVersion: 1

providers:
  - name: "lgtm-dashboards"
    orgId: 1
    type: file
    disableDeletion: true
    updateIntervalSeconds: 30
    allowUiUpdates: false
    options:
      path: /etc/lgtm/grafana/dashboards
      foldersFromFilesStructure: true
PROVIDER
  ok "Created dashboard provider: ${DASHBOARD_PROVIDER}"
  info "  disableDeletion=true  → UI cannot delete provisioned dashboards"
  info "  allowUiUpdates=false  → UI edits are discarded on restart (code is truth)"
  info "  foldersFromFilesStructure=true → subdir names become Grafana folder names"
else
  ok "Dashboard provider already exists: ${DASHBOARD_PROVIDER}"
fi

# Dashboard subdirs — organised by audience, not by data source.
# Each subdir becomes a named folder in the Grafana UI (foldersFromFilesStructure).
# .gitkeep files ensure dirs are tracked in git before JSON files exist.
declare -A DASHBOARD_SUBDIRS=(
  # subdir → what belongs here
  ["infrastructure"]="node-exporter.json, blackbox.json"
  ["reliability"]="golden-signals.json, slo-error-budget.json, http-errors.json"
  ["delivery"]="dora-metrics.json"
  ["observability"]="unified.json"
)

for subdir in "${!DASHBOARD_SUBDIRS[@]}"; do
  touch "/etc/lgtm/grafana/dashboards/${subdir}/.gitkeep"
  ok "Dashboard slot ready: /etc/lgtm/grafana/dashboards/${subdir}/ → ${DASHBOARD_SUBDIRS[$subdir]}"
done

# Dashboard files: root:grafana 640
# Grafana reads these as the grafana user. Root deploys them (via git pull,
# ansible, or manual copy). Grafana never writes back to provisioned files.
# If you see "permission denied" in grafana logs on startup, it's this.
find /etc/lgtm/grafana/dashboards -type f -exec chmod 640 {} \;
find /etc/lgtm/grafana/provisioning -type f -exec chmod 640 {} \;
ok "Dashboard file permissions set (640 — root:grafana)"

# Explain the deployment workflow in a README inside the dashboards dir
DASH_README=/etc/lgtm/grafana/dashboards/README.md
if [[ ! -f "$DASH_README" ]]; then
  cat > "$DASH_README" << 'DASHREADME'
# Grafana Dashboard Provisioning

## How it works

Grafana reads JSON/YAML files from this directory on startup and on every
`updateIntervalSeconds` (30s). Changes to files here are picked up without
a Grafana restart.

## Directory → Grafana folder mapping

Because `foldersFromFilesStructure: true` is set in provider.yml, each
subdirectory name here becomes a Grafana folder name in the UI.

Directories are organised by AUDIENCE, not by data source:

  infrastructure/   → "infrastructure" folder  — ops team
    node-exporter.json      CPU, memory, disk, network, load averages
    blackbox.json           uptime, SSL expiry, probe success rate

  reliability/      → "reliability" folder      — SRE team
    golden-signals.json     latency, traffic, errors, saturation (cross-service)
    slo-error-budget.json   SLI vs SLO gauges, burn rate, budget remaining
    http-errors.json        4xx vs 5xx breakdown by endpoint and service

  delivery/         → "delivery" folder         — engineering leads
    dora-metrics.json       deployment freq, lead time, CFR, MTTR

  observability/    → "observability" folder     — anyone debugging
    unified.json            metric spike → correlated logs → trace drill-down

WHY THIS STRUCTURE:
Golden signals and HTTP error dashboards are cross-service — they pull from
Prometheus, Loki, and the fake-service simultaneously. Grouping them under
node-exporter/ or blackbox/ (the data sources) would be semantically wrong.
Grouping by audience makes clear who should be looking at what and why.

## Deploying a new dashboard

1. Export from Grafana UI: Share → Export → Save to file
2. Copy the JSON here: cp my-dashboard.json /etc/lgtm/grafana/dashboards/node-exporter/
3. Fix ownership:       chown root:grafana /etc/lgtm/grafana/dashboards/node-exporter/my-dashboard.json
4. Fix permissions:     chmod 640 /etc/lgtm/grafana/dashboards/node-exporter/my-dashboard.json
5. Grafana picks it up within 30 seconds — no restart needed.

## Rules
- Never edit JSON files through the Grafana UI (allowUiUpdates=false — changes are lost on restart)
- Always version-control dashboard JSON files in git
- Remove .gitkeep files when you add real dashboard JSON to a subdir
DASHREADME
  chown root:grafana "$DASH_README"
  chmod 640 "$DASH_README"
  ok "Created dashboard deployment README"
fi

# 1.4 Data directories 
info "Creating data directories under /var/lib/lgtm/..."

for dir in "${DATA_DIRS[@]}"; do
  if mkdir -p "$dir"; then
    ok "Created: ${dir}"
  else
    fail "Failed to create: ${dir}"
  fi
done

# Data dirs: owned by the service user — only they write here
chown -R prometheus:prometheus   /var/lib/lgtm/prometheus
chown -R loki:loki               /var/lib/lgtm/loki
chown -R tempo:tempo             /var/lib/lgtm/tempo
chown -R grafana:grafana         /var/lib/lgtm/grafana

# Data dirs: service user full control, no world access
find /var/lib/lgtm -type d -exec chmod 750 {} \;
ok "Data directory permissions set (750 — service user owns)"

# 1.5 Log directory 
info "Creating log directory..."
mkdir -p "$LOG_DIR"
chown root:root "$LOG_DIR"
chmod 755 "$LOG_DIR"

# Per-service log dirs (for services that write log files instead of stdout)
for svc in prometheus loki tempo grafana alertmanager; do
  mkdir -p "${LOG_DIR}/${svc}"
  # Owned by service user so it can write
  chown "${svc}:${svc}" "${LOG_DIR}/${svc}" 2>/dev/null || true
  chmod 750 "${LOG_DIR}/${svc}"
done
ok "Log directory structure created under ${LOG_DIR}"

# 1.6 systemd unit directory 
info "Confirming systemd unit directory..."
if [[ -d "$SYSTEMD_DIR" ]]; then
  ok "systemd unit directory exists: ${SYSTEMD_DIR}"
else
  fail "systemd unit directory not found: ${SYSTEMD_DIR} — is systemd installed?"
fi

# 1.7 Create /etc/lgtm/env — shared environment file
info "Creating shared environment file at /etc/lgtm/env..."

if [[ ! -f /etc/lgtm/env ]]; then
  cat > /etc/lgtm/env << 'ENV'
# LGTM Stack — shared environment variables
# Sourced by systemd unit files via EnvironmentFile=/etc/lgtm/env
# Secrets (Slack webhook etc) go in /etc/lgtm/secrets — see below

# Retention periods
PROMETHEUS_RETENTION_TIME=30d
LOKI_RETENTION_PERIOD=720h
TEMPO_RETENTION_PERIOD=720h

# Service addresses (localhost — not container names)
PROMETHEUS_ADDR=127.0.0.1:9090
LOKI_ADDR=127.0.0.1:3100
TEMPO_ADDR=127.0.0.1:3200
ALERTMANAGER_ADDR=127.0.0.1:9093

# OTel endpoint for fake-service
OTEL_ENDPOINT=http://127.0.0.1:4317
SERVICE_NAME=fake-service
ENV
  chown root:root /etc/lgtm/env
  chmod 644 /etc/lgtm/env
  ok "Created /etc/lgtm/env"
else
  ok "/etc/lgtm/env already exists — skipping"
fi

# 1.8 Create /etc/lgtm/secrets — secrets file (mode 600) 
info "Creating secrets file at /etc/lgtm/secrets..."

if [[ ! -f /etc/lgtm/secrets ]]; then
  cat > /etc/lgtm/secrets << 'SECRETS'
# LGTM Stack — secrets
# This file is mode 600 (root read-only).
# Sourced by Alertmanager unit via EnvironmentFile=/etc/lgtm/secrets
# Replace the placeholder below with your actual Slack webhook URL.

SLACK_WEBHOOK_URL=https://hooks.slack.com/services/
GF_SECURITY_ADMIN_PASSWORD=change_me_in_production
SECRETS
  chown root:root /etc/lgtm/secrets
  chmod 600 /etc/lgtm/secrets
  ok "Created /etc/lgtm/secrets (mode 600 — root only)"
  warn "ACTION REQUIRED: Edit /etc/lgtm/secrets and set your SLACK_WEBHOOK_URL before Phase 4"
else
  ok "/etc/lgtm/secrets already exists — skipping"
fi

# 1.9 Verify final ownership 
info "Verifying directory ownership and permissions..."

verify_ownership() {
  local dir="$1" expected_owner="$2"
  local actual_owner
  actual_owner=$(stat -c '%U' "$dir" 2>/dev/null)
  if [[ "$actual_owner" == "$expected_owner" ]]; then
    ok "Ownership OK: ${dir} → ${actual_owner}"
  else
    fail "Wrong ownership on ${dir}: expected ${expected_owner}, got ${actual_owner}"
  fi
}

verify_ownership /var/lib/lgtm/prometheus prometheus
verify_ownership /var/lib/lgtm/loki       loki
verify_ownership /var/lib/lgtm/tempo      tempo
verify_ownership /var/lib/lgtm/grafana    grafana

verify_perm() {
  local path="$1" expected_perm="$2"
  local actual_perm
  actual_perm=$(stat -c '%a' "$path" 2>/dev/null)
  if [[ "$actual_perm" == "$expected_perm" ]]; then
    ok "Permissions OK: ${path} → ${actual_perm}"
  else
    fail "Wrong permissions on ${path}: expected ${expected_perm}, got ${actual_perm}"
  fi
}

verify_perm /etc/lgtm/secrets 600
verify_perm /etc/lgtm/env    644

# 1.10 Print the full directory tree 
section "DIRECTORY TREE SUMMARY"
if command -v tree &>/dev/null; then
  tree /opt/lgtm /etc/lgtm /var/lib/lgtm /var/log/lgtm -d --noreport 2>/dev/null
else
  find /opt/lgtm /etc/lgtm /var/lib/lgtm /var/log/lgtm -type d 2>/dev/null | sort | \
    sed 's|[^/]*/|  |g;s|  \([^/]\)|└─ \1|'
fi

# ═════════════════════════════════════════════════════════════════════════════
# FINAL REPORT
# ═════════════════════════════════════════════════════════════════════════════

section "PHASE 0 + 1 SUMMARY"

echo ""
if [[ "$ERRORS" -eq 0 && "$WARNINGS" -eq 0 ]]; then
  echo -e "${GRN}${BLD}✓ All checks passed. Zero errors, zero warnings.${RST}"
  echo -e "${GRN}  Ready for Phase 2 — binary installation.${RST}"
elif [[ "$ERRORS" -eq 0 ]]; then
  echo -e "${YEL}${BLD}⚠ Completed with ${WARNINGS} warning(s) and 0 errors.${RST}"
  echo -e "${YEL}  Review warnings above before proceeding to Phase 2.${RST}"
else
  echo -e "${RED}${BLD}✗ Completed with ${ERRORS} error(s) and ${WARNINGS} warning(s).${RST}"
  echo -e "${RED}  Fix all errors before proceeding to Phase 2.${RST}"
  echo ""
  echo -e "${RED}  Errors will cause service startup failures in later phases.${RST}"
  echo -e "${RED}  Do not skip them.${RST}"
fi

echo ""
echo -e "${BLD}Next steps:${RST}"
echo -e "  1. ${YEL}Edit /etc/lgtm/secrets${RST} — set SLACK_WEBHOOK_URL and GF_SECURITY_ADMIN_PASSWORD"
echo -e "  2. ${YEL}Edit /etc/lgtm/env${RST} — review and adjust retention periods if needed"
echo -e "  3. Run ${BLD}01-install-binaries.sh${RST} (Phase 2)"
echo ""

exit $ERRORS

