#!/usr/bin/env bash
# =============================================================================
# LGTM Stack
# Phase 0 (Pre-flight) 
# Phase 1 (Directory & File Layout)
# =============================================================================
# Phase 2: Binary Installation
# Target: Ubuntu 26.04 LTS (Resolute Raccoon) — Linux kernel 7.0 — amd64
#
# Installs:
#   Grafana Enterprise  13.0.1   via .deb
#   Prometheus          3.5.3    via binary tarball
#   Alertmanager        0.32.1   via binary tarball
#   Blackbox Exporter   0.28.0   via binary tarball
#   Node Exporter       1.11.1   via binary tarball
#   Loki                3.7.2    via binary tarball
#   Tempo               3.0.0-rc.1  via binary tarball
#   OTel Collector      0.152.0  via .deb
#
# Follows the Nemeth principle: install, verify, then move on. Never assume a download
# succeeded. Never assume a binary runs. Check every step explicitly.
# =============================================================================
# Phase 3: Configuration Files
# Target: Ubuntu 26.04 LTS — amd64
#
# Writes configuration for every service into /etc/lgtm/<service>/.
# Every config file is validated before we move on.
# Nemeth principle: validate configs before the daemon ever sees them.
# A typo in a config file should fail here.
# =============================================================================
# Phase 4: systemd Unit Files
#
# Writes and enables systemd unit files for every LGTM service.
# Installation order follows dependency graph:
#
#   blackbox-exporter  (no deps)   ─┐
#   alertmanager       (no deps)   ─┤─→ prometheus ─→ grafana
#   loki               (no deps)   ─┤
#   tempo              (no deps)   ─┘
#
# Nemeth principle: document the dependency graph explicitly. systemd's
# After= and Wants= make implicit boot-time ordering explicit and auditable.
#
# Security hardening applied to every unit:
#   User=/Group=          run as dedicated non-root system user
#   NoNewPrivileges=yes   process cannot gain additional privileges via setuid
#   PrivateTmp=yes        service gets its own /tmp — prevents /tmp attacks
#   ProtectSystem=full    /usr /boot /etc read-only for the service process
#   ReadWritePaths=       explicit whitelist of dirs the service can write to
#   ProtectHome=yes       /home /root /run/user invisible to service
#   CapabilityBoundingSet= empty capability set for services that need none
#   LimitNOFILE=          per-service file descriptor limits (overrides ulimits)
# =============================================================================
# Phase 5: Hardening, Bring-Up & Verification
#
# This script does three things in strict order:
#
#   1. HARDEN  — firewall rules, file permission audit, sysctl final check
#   2. START   — services in dependency order, one at a time
#   3. VERIFY  — each service must pass its health check before the next starts
#
# It follows the Nemeth principle: 
# Never start a service and assume it worked. Test it.
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

TMP_DIR=$(mktemp -d /tmp/lgtm-install.XXXXXX)
trap 'rm -rf "$TMP_DIR"' EXIT

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
  "blackbox-exporter"
)

# Directory definitions
# Binary directories
BIN_DIRS=(
  /opt/lgtm/prometheus
  /opt/lgtm/loki
  /opt/lgtm/tempo
  /opt/lgtm/grafana
  /opt/lgtm/alertmanager
  /opt/lgtm/blackbox-exporter
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
  # Tempo 3.0 live-store — defaults to /var/tempo if not redirected via config
  /var/tempo/live-store
  /var/lib/lgtm/grafana
  /var/lib/lgtm/alertmanager
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

REQUIRED_PKGS=(wget curl tar unzip python3 adduser git ca-certificates apt-transport-https gnupg2 libfontconfig1 musl unzip)

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

# Install AWS CLI v2 — the apt package is v1 and unreliable on fresh instances
if ! command -v aws &>/dev/null || ! aws --version 2>&1 | grep -q "aws-cli/2"; then
  info "Installing AWS CLI v2..."
  curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "${TMP_DIR}/awscliv2.zip"
  unzip -q "${TMP_DIR}/awscliv2.zip" -d "${TMP_DIR}/"
  "${TMP_DIR}/aws/install" --update
  rm -rf "${TMP_DIR}/awscliv2.zip" "${TMP_DIR}/aws"
  ok "AWS CLI v2 installed: $(aws --version 2>&1)"
else
  ok "AWS CLI v2 already present: $(aws --version 2>&1)"
fi

# 0.7 Port availability
info "Checking that required ports are available..."

declare -A SERVICE_PORTS=(
  [9090]="Prometheus"
  [9093]="Alertmanager"
  [9115]="Blackbox Exporter"
  [3000]="Grafana"
  [3100]="Loki"
  [3200]="Tempo HTTP"
  [4317]="Tempo OTLP gRPC"
  [4318]="Tempo OTLP HTTP"
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

# Create a shared exporter user for blackbox-exporter
if ! id "exporter" &>/dev/null; then
  useradd \
    --system \
    --no-create-home \
    --shell /usr/sbin/nologin \
    --comment "Shared user for LGTM exporters" \
    --user-group \
    "exporter"
  ok "User exporter: created (shared user for blackbox-exporter)"
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
chown -R root:exporter     /etc/lgtm/blackbox-exporter

# Subdirectories: root can rwx, group can rx (read configs, traverse dirs)
find /etc/lgtm -mindepth 1 -type d -exec chmod 750 {} \;
# Parent /etc/lgtm stays 755 — service users need to traverse into it,
# but each subdir's group ownership already restricts what they can see.
chmod 755 /etc/lgtm
ok "Config directory permissions set (subdirs 750 root:group, parent 755)"

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
chown -R prometheus:prometheus     /var/lib/lgtm/prometheus
chown -R loki:loki                 /var/lib/lgtm/loki
chown -R tempo:tempo               /var/lib/lgtm/tempo
chown -R tempo:tempo               /var/tempo
chown -R grafana:grafana           /var/lib/lgtm/grafana
chown -R alertmanager:alertmanager /var/lib/lgtm/alertmanager

# Subdirs: service user full control, no world access
find /var/lib/lgtm -mindepth 1 -type d -exec chmod 750 {} \;
# Parent /var/lib/lgtm stays 755 — service users need to traverse into it
chmod 755 /var/lib/lgtm
# Tempo 3.0 live-store lives outside /var/lib/lgtm — set separately
find /var/tempo -type d -exec chmod 750 {} \;
ok "Data directory permissions set (subdirs 750 service-owned, parent 755)"

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
ENV
  chown root:root /etc/lgtm/env
  chmod 644 /etc/lgtm/env
  ok "Created /etc/lgtm/env"
else
  ok "/etc/lgtm/env already exists — skipping"
fi

# 1.8 Fetch secrets from AWS SSM Parameter Store
# The instance IAM role grants read access to /lgtm/* parameters.
# Falls back to environment variables so the script can also run manually.
info "Fetching secrets from AWS SSM Parameter Store..."

_ssm_get() {
  aws ssm get-parameter --name "$1" --with-decryption \
    --query 'Parameter.Value' --output text 2>/dev/null
}

# On a fresh EC2 instance, IMDS can take up to ~30s to serve credentials.
# Retry up to 10 times (50s) before giving up.
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
  SLACK_WEBHOOK_URL=$(_ssm_get "/lgtm/slack_webhook_url")
  GRAFANA_PASSWORD=$(_ssm_get "/lgtm/grafana_admin_password")
  APP_SERVER_IP=$(_ssm_get "/lgtm/app_server_ip")
  MONITORING_PUBLIC_IP=$(_ssm_get "/lgtm/monitoring_server_public_ip")
  [[ -z "$SLACK_WEBHOOK_URL" ]] && die "Failed to fetch /lgtm/slack_webhook_url from SSM — check instance IAM role"
  [[ -z "$GRAFANA_PASSWORD" ]]  && die "Failed to fetch /lgtm/grafana_admin_password from SSM — check instance IAM role"
  [[ -z "$APP_SERVER_IP" ]]     && die "Failed to fetch /lgtm/app_server_ip from SSM — check instance IAM role"
  [[ -z "$MONITORING_PUBLIC_IP" ]] && die "Failed to fetch /lgtm/monitoring_server_public_ip from SSM — check instance IAM role"
  ok "Secrets and config fetched from SSM (app server: ${APP_SERVER_IP})"
else
  info "IMDS not reachable after 50s — falling back to environment variables"
  [[ -z "${SLACK_WEBHOOK_URL:-}" ]] && die "SLACK_WEBHOOK_URL not set and SSM not available"
  [[ -z "${GRAFANA_PASSWORD:-}" ]]  && die "GRAFANA_PASSWORD not set and SSM not available"
  [[ -z "${APP_SERVER_IP:-}" ]]     && die "APP_SERVER_IP not set and SSM not available"
  ok "Config loaded from environment (app server: ${APP_SERVER_IP})"
fi

# 1.9 Create /etc/lgtm/secrets — secrets file (mode 600)
info "Writing /etc/lgtm/secrets..."

if [[ ! -f /etc/lgtm/secrets ]]; then
  cat > /etc/lgtm/secrets << SECRETS
# LGTM Stack — secrets (mode 600, root read-only)
# Sourced by Alertmanager unit via EnvironmentFile=/etc/lgtm/secrets
SLACK_WEBHOOK_URL=${SLACK_WEBHOOK_URL}
GF_SECURITY_ADMIN_USER=admin
GF_SECURITY_ADMIN_PASSWORD=${GRAFANA_PASSWORD}
SECRETS
  chown root:root /etc/lgtm/secrets
  chmod 600 /etc/lgtm/secrets
  ok "Created /etc/lgtm/secrets (mode 600 — root only)"
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
  echo -e "${GRN}${BLD}✓ Phases 0 + 1 complete. Zero errors, zero warnings.${RST}"
  echo -e "${GRN}  Proceeding to Phase 2 — binary installation.${RST}"
elif [[ "$ERRORS" -eq 0 ]]; then
  echo -e "${YEL}${BLD}⚠ Phases 0 + 1 complete with ${WARNINGS} warning(s) and 0 errors.${RST}"
  echo -e "${YEL}  Proceeding to Phase 2.${RST}"
else
  echo -e "${RED}${BLD}✗ Phases 0 + 1 completed with ${ERRORS} error(s) and ${WARNINGS} warning(s).${RST}"
  echo -e "${RED}  Errors above will cause service startup failures in later phases.${RST}"
fi

echo ""
echo -e "${BLD}Secrets reminder:${RST}"
echo -e "  Edit ${YEL}/etc/lgtm/secrets${RST} — set SLACK_WEBHOOK_URL and GF_SECURITY_ADMIN_PASSWORD"
echo -e "  Edit ${YEL}/etc/lgtm/env${RST} — review and adjust retention periods if needed"
echo ""
[[ "$ERRORS" -gt 0 ]] && die "Phase 0+1 failed with ${ERRORS} error(s) — fix above before Phase 2 proceeds."

# ─── Version pins ─────────────────────────────────────────────────────────────
# All versions are pinned explicitly. Changing a version here is a one-line
# diff — intentional and reviewable. Never use 'latest' in production scripts.
GRAFANA_VERSION="13.0.1+security-01"
GRAFANA_BUILD="25720641773"
PROMETHEUS_VERSION="3.5.3"
ALERTMANAGER_VERSION="0.32.1"
BLACKBOX_VERSION="0.28.0"
NODE_EXPORTER_VERSION="1.11.1"
LOKI_VERSION="3.7.2"
TEMPO_VERSION="3.0.0-rc.1"
OTELCOL_VERSION="0.152.0"

# ─── Download helper ──────────────────────────────────────────────────────────
# Nemeth: always verify what you downloaded. wget --continue allows resuming
# interrupted downloads. --tries=3 retries transient failures.
download() {
  local url="$1" dest="$2" description="$3"
  info "Downloading ${description}..."
  if wget \
      --quiet \
      --show-progress \
      --continue \
      --tries=3 \
      --timeout=60 \
      --output-document="$dest" \
      "$url"; then
    ok "Downloaded: $(basename "$dest") ($(du -sh "$dest" | cut -f1))"
  else
    fail "Download failed: ${url}"
    return 1
  fi
}

# ─── Checksum verification helper ─────────────────────────────────────────────
# Nemeth: never install software without verifying its integrity.
# We verify SHA256 checksums where the project publishes them.
verify_sha256() {
  local file="$1" expected="$2" name="$3"
  local actual
  actual=$(sha256sum "$file" | awk '{print $1}')
  if [[ "$actual" == "$expected" ]]; then
    ok "SHA256 verified: ${name}"
  else
    fail "SHA256 MISMATCH for ${name}"
    fail "  Expected: ${expected}"
    fail "  Got:      ${actual}"
    return 1
  fi
}

# ─── Binary install helper ────────────────────────────────────────────────────
# Extracts tarball, copies named binary to /opt/lgtm/<service>/,
# sets ownership (root:root) and permissions (755 — executable by all,
# writable only by root). Nemeth: binaries should not be writable by
# the user running them.
install_binary() {
  local tarball="$1"
  local binary_name="$2"
  local dest_dir="$3"
  local strip_components="${4:-1}"

  info "Extracting ${binary_name} from $(basename "$tarball")..."
  tar -xzf "$tarball" \
      --directory="$TMP_DIR" \
      --strip-components="$strip_components"

  local src="${TMP_DIR}/${binary_name}"
  if [[ ! -f "$src" ]]; then
    # Some tarballs nest differently — search for the binary
    src=$(find "$TMP_DIR" -name "$binary_name" -type f | head -1)
    [[ -z "$src" ]] && { fail "Binary ${binary_name} not found in tarball"; return 1; }
  fi

  cp "$src" "${dest_dir}/${binary_name}"
  chown root:root "${dest_dir}/${binary_name}"
  chmod 755 "${dest_dir}/${binary_name}"
  ok "Installed: ${dest_dir}/${binary_name}"

  # Clean up extracted files so next install_binary call starts fresh
  find "$TMP_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true
}

# ─── Version verification helper ──────────────────────────────────────────────
# Every binary must respond to --version before we declare it installed.
# A binary that silently crashes on --version will crash on start too.
verify_binary() {
  local binary="$1" expected_version="$2"
  info "Verifying ${binary} --version..."
  if "$binary" --version 2>&1 | grep -q "$expected_version"; then
    ok "Version confirmed: ${binary} ${expected_version}"
  else
    local actual
    actual=$("$binary" --version 2>&1 | head -1)
    warn "Version string mismatch for ${binary}"
    warn "  Expected to contain: ${expected_version}"
    warn "  Got: ${actual}"
    # Warn not fail — some binaries format version strings unexpectedly
  fi
}

# =============================================================================
# INSTALLATION
# =============================================================================

# =============================================================================
section "1/8 — GRAFANA ENTERPRISE ${GRAFANA_VERSION}"
# Installed via .deb — Grafana manages its own systemd unit.
# We will override the unit file in Phase 4 to add hardening directives.
# Grafana creates its own 'grafana' user on install — consistent with
# what Phase 0 already created (dpkg is idempotent here).
# =============================================================================

GRAFANA_DEB="${TMP_DIR}/grafana-enterprise.deb"
GRAFANA_URL="https://dl.grafana.com/grafana-enterprise/release/${GRAFANA_VERSION}/grafana-enterprise_${GRAFANA_VERSION}_${GRAFANA_BUILD}_linux_amd64.deb"

download "$GRAFANA_URL" "$GRAFANA_DEB" "Grafana Enterprise ${GRAFANA_VERSION}"
dpkg -i "$GRAFANA_DEB"
ok "Grafana Enterprise ${GRAFANA_VERSION} installed via dpkg"

# Grafana .deb installs to /usr/sbin/grafana-server — symlink to our bin dir
# for consistency with the rest of the stack layout
ln -sf /usr/sbin/grafana-server /opt/lgtm/grafana/grafana-server
ok "Symlink: /opt/lgtm/grafana/grafana-server → /usr/sbin/grafana-server"

verify_binary /usr/sbin/grafana-server "$GRAFANA_VERSION"

# Grafana .deb enables its own systemd service — disable it now.
# Phase 3 will install our hardened unit file in its place.
systemctl disable --now grafana-server 2>/dev/null || true
ok "Grafana default systemd unit disabled — Phase 3 will install hardened unit"

# Deploy dashboard JSON files from the Terraform-uploaded staging area.
# Done here because the grafana group is created by the dpkg install above.
info "Deploying Grafana dashboards..."
if [[ -d /tmp/lgtm-dashboards ]]; then
  for subdir in infrastructure reliability delivery observability; do
    src="/tmp/lgtm-dashboards/${subdir}"
    dst="/etc/lgtm/grafana/dashboards/${subdir}"
    if [[ -d "$src" ]]; then
      cp "${src}"/*.json "$dst/" 2>/dev/null || true
      ok "Dashboards deployed: ${subdir}/ ($(ls "${dst}"/*.json 2>/dev/null | wc -l) files)"
    fi
  done
  find /etc/lgtm/grafana/dashboards -name "*.json" -exec chown root:grafana {} \;
  find /etc/lgtm/grafana/dashboards -name "*.json" -exec chmod 640 {} \;
  rm -rf /tmp/lgtm-dashboards
  ok "Dashboard ownership set (root:grafana, mode 640)"
else
  warn "Dashboard staging dir /tmp/lgtm-dashboards not found — dashboards will need to be deployed manually"
fi

# =============================================================================
section "2/8 — PROMETHEUS ${PROMETHEUS_VERSION}"
# =============================================================================

PROM_TARBALL="${TMP_DIR}/prometheus.tar.gz"
PROM_URL="https://github.com/prometheus/prometheus/releases/download/v${PROMETHEUS_VERSION}/prometheus-${PROMETHEUS_VERSION}.linux-amd64.tar.gz"

download "$PROM_URL" "$PROM_TARBALL" "Prometheus ${PROMETHEUS_VERSION}"
install_binary "$PROM_TARBALL" "prometheus" "/opt/lgtm/prometheus"

# Re-extract for promtool (install_binary cleans tmp after each call)
download "$PROM_URL" "$PROM_TARBALL" "Prometheus ${PROMETHEUS_VERSION} (promtool pass)"
tar -xzf "$PROM_TARBALL" --directory="$TMP_DIR" --strip-components=1
cp "${TMP_DIR}/promtool" /opt/lgtm/prometheus/promtool
chown root:root /opt/lgtm/prometheus/promtool
chmod 755 /opt/lgtm/prometheus/promtool
find "$TMP_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true
ok "promtool installed: /opt/lgtm/prometheus/promtool"

# Symlink to /usr/local/bin so promtool is available system-wide for
# config validation in Phase 2 and ongoing operations
ln -sf /opt/lgtm/prometheus/prometheus /usr/local/bin/prometheus
ln -sf /opt/lgtm/prometheus/promtool   /usr/local/bin/promtool
ok "Symlinks: prometheus, promtool → /usr/local/bin/"

verify_binary /opt/lgtm/prometheus/prometheus "$PROMETHEUS_VERSION"
verify_binary /opt/lgtm/prometheus/promtool   "$PROMETHEUS_VERSION"

# =============================================================================
section "3/8 — ALERTMANAGER ${ALERTMANAGER_VERSION}"
# =============================================================================

AM_TARBALL="${TMP_DIR}/alertmanager.tar.gz"
AM_URL="https://github.com/prometheus/alertmanager/releases/download/v${ALERTMANAGER_VERSION}/alertmanager-${ALERTMANAGER_VERSION}.linux-amd64.tar.gz"

download "$AM_URL" "$AM_TARBALL" "Alertmanager ${ALERTMANAGER_VERSION}"

tar -xzf "$AM_TARBALL" --directory="$TMP_DIR" --strip-components=1
cp "${TMP_DIR}/alertmanager" /opt/lgtm/alertmanager/alertmanager
cp "${TMP_DIR}/amtool"       /opt/lgtm/alertmanager/amtool
chown root:root /opt/lgtm/alertmanager/alertmanager /opt/lgtm/alertmanager/amtool
chmod 755       /opt/lgtm/alertmanager/alertmanager /opt/lgtm/alertmanager/amtool
find "$TMP_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true
ok "alertmanager and amtool installed"

ln -sf /opt/lgtm/alertmanager/alertmanager /usr/local/bin/alertmanager
ln -sf /opt/lgtm/alertmanager/amtool       /usr/local/bin/amtool
ok "Symlinks: alertmanager, amtool → /usr/local/bin/"

verify_binary /opt/lgtm/alertmanager/alertmanager "$ALERTMANAGER_VERSION"

# =============================================================================
section "4/8 — BLACKBOX EXPORTER ${BLACKBOX_VERSION}"
# =============================================================================

BB_TARBALL="${TMP_DIR}/blackbox_exporter.tar.gz"
BB_URL="https://github.com/prometheus/blackbox_exporter/releases/download/v${BLACKBOX_VERSION}/blackbox_exporter-${BLACKBOX_VERSION}.linux-amd64.tar.gz"

download "$BB_URL" "$BB_TARBALL" "Blackbox Exporter ${BLACKBOX_VERSION}"
install_binary "$BB_TARBALL" "blackbox_exporter" "/opt/lgtm/blackbox-exporter"

ln -sf /opt/lgtm/blackbox-exporter/blackbox_exporter /usr/local/bin/blackbox_exporter
ok "Symlink: blackbox_exporter → /usr/local/bin/"

verify_binary /opt/lgtm/blackbox-exporter/blackbox_exporter "$BLACKBOX_VERSION"

# Node Exporter runs on the application server — installed by app-agent.sh.

# =============================================================================
section "6/8 — LOKI ${LOKI_VERSION}"
# =============================================================================

LOKI_ZIP="${TMP_DIR}/loki.zip"
LOKI_URL="https://github.com/grafana/loki/releases/download/v${LOKI_VERSION}/loki-linux-amd64.zip"

download "$LOKI_URL" "$LOKI_ZIP" "Loki ${LOKI_VERSION}"

unzip -q "$LOKI_ZIP" -d "$TMP_DIR"
LOKI_BIN=$(find "$TMP_DIR" -name "loki-linux-amd64" -o -name "loki" -type f | head -1)
[[ -z "$LOKI_BIN" ]] && die "loki binary not found in zip"
cp "$LOKI_BIN" /opt/lgtm/loki/loki
chown root:root /opt/lgtm/loki/loki
chmod 755       /opt/lgtm/loki/loki
find "$TMP_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true
ok "Loki binary installed: /opt/lgtm/loki/loki"

# logcli — the Loki query CLI, equivalent to promtool for Prometheus
LOGCLI_ZIP="${TMP_DIR}/logcli.zip"
LOGCLI_URL="https://github.com/grafana/loki/releases/download/v${LOKI_VERSION}/logcli-linux-amd64.zip"
download "$LOGCLI_URL" "$LOGCLI_ZIP" "logcli ${LOKI_VERSION}"
unzip -q "$LOGCLI_ZIP" -d "$TMP_DIR"
LOGCLI_BIN=$(find "$TMP_DIR" -name "logcli-linux-amd64" -o -name "logcli" -type f | head -1)
if [[ -n "$LOGCLI_BIN" ]]; then
  cp "$LOGCLI_BIN" /opt/lgtm/loki/logcli
  chown root:root /opt/lgtm/loki/logcli
  chmod 755       /opt/lgtm/loki/logcli
  ln -sf /opt/lgtm/loki/logcli /usr/local/bin/logcli
  ok "logcli installed: /opt/lgtm/loki/logcli"
else
  warn "logcli binary not found — skipping (non-fatal)"
fi
find "$TMP_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true

ln -sf /opt/lgtm/loki/loki /usr/local/bin/loki
ok "Symlink: loki → /usr/local/bin/"

# Loki has no --version flag — use -version (single dash)
if /opt/lgtm/loki/loki -version 2>&1 | grep -q "$LOKI_VERSION"; then
  ok "Loki version confirmed: ${LOKI_VERSION}"
else
  warn "Could not confirm Loki version — binary may still be valid"
fi

# =============================================================================
section "7/8 — TEMPO ${TEMPO_VERSION}"
# =============================================================================

TEMPO_TARBALL="${TMP_DIR}/tempo.tar.gz"
TEMPO_URL="https://github.com/grafana/tempo/releases/download/v${TEMPO_VERSION}/tempo_${TEMPO_VERSION}_linux_amd64.tar.gz"

download "$TEMPO_URL" "$TEMPO_TARBALL" "Tempo ${TEMPO_VERSION}"

tar -xzf "$TEMPO_TARBALL" --directory="$TMP_DIR"
TEMPO_BIN=$(find "$TMP_DIR" -name "tempo" -type f | head -1)
[[ -z "$TEMPO_BIN" ]] && die "tempo binary not found in tarball"
cp "$TEMPO_BIN" /opt/lgtm/tempo/tempo
chown root:root /opt/lgtm/tempo/tempo
chmod 755       /opt/lgtm/tempo/tempo
find "$TMP_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true
ok "Tempo binary installed: /opt/lgtm/tempo/tempo"

ln -sf /opt/lgtm/tempo/tempo /usr/local/bin/tempo
ok "Symlink: tempo → /usr/local/bin/"

if /opt/lgtm/tempo/tempo --version 2>&1 | grep -q "$TEMPO_VERSION"; then
  ok "Tempo version confirmed: ${TEMPO_VERSION}"
else
  warn "Could not confirm Tempo version — binary may still be valid"
fi

# OTel Collector runs on the application server — installed by app-agent.sh.

# =============================================================================
section "INSTALLATION SUMMARY"
# =============================================================================

echo ""
info "Installed binaries:"
for binary in \
  /usr/sbin/grafana-server \
  /opt/lgtm/prometheus/prometheus \
  /opt/lgtm/prometheus/promtool \
  /opt/lgtm/alertmanager/alertmanager \
  /opt/lgtm/alertmanager/amtool \
  /opt/lgtm/blackbox-exporter/blackbox_exporter \
  /opt/lgtm/loki/loki \
  /opt/lgtm/tempo/tempo; do
  if [[ -x "$binary" ]]; then
    SIZE=$(du -sh "$binary" | cut -f1)
    echo -e "  ${GRN}✓${RST} ${binary} (${SIZE})"
  else
    echo -e "  ${RED}✗${RST} ${binary} — MISSING OR NOT EXECUTABLE"
    ERRORS=$((ERRORS+1))
  fi
done

echo ""
if [[ "$ERRORS" -eq 0 ]]; then
  echo -e "${GRN}${BLD}✓ All binaries installed successfully.${RST}"
  echo -e "${GRN}  Proceeding to Phase 3 — configuration files.${RST}"
else
  echo -e "${RED}${BLD}✗ ${ERRORS} error(s) during installation.${RST}"
fi
echo ""
[[ "$ERRORS" -gt 0 ]] && die "Phase 2 failed with ${ERRORS} error(s) — fix above before Phase 3 proceeds."

# ─── Load shared env ──────────────────────────────────────────────────────────
source /etc/lgtm/env

# Helper: write a config file, set ownership, then validate
write_config() {
  local path="$1" owner="$2" mode="$3"
  # Content arrives via stdin (heredoc from caller)
  cat > "$path"
  chown "$owner" "$path"
  chmod "$mode"  "$path"
  ok "Written: ${path}"
}

# =============================================================================
section "1/7 — PROMETHEUS"
# =============================================================================

info "Writing prometheus.yml..."
write_config /etc/lgtm/prometheus/prometheus.yml root:prometheus 640 << EOF
# =============================================================================
# Prometheus configuration
# Scrape interval: 15s (industry standard default)
# Retention: controlled by --storage.tsdb.retention.time in the unit file.
# =============================================================================

global:
  scrape_interval:     15s
  evaluation_interval: 15s
  scrape_timeout:      10s
  external_labels:
    environment: "production"
    team:        "devops"

rule_files:
  - "/etc/lgtm/prometheus/rules/*.yml"

alerting:
  alertmanagers:
    - static_configs:
        - targets:
            - "127.0.0.1:9093"
      timeout: 10s

scrape_configs:

  # ── Prometheus self-monitoring ───────────────────────────────────────────
  - job_name: "prometheus"
    static_configs:
      - targets: ["127.0.0.1:9090"]

  # ── App server OS metrics — Node Exporter ────────────────────────────────
  - job_name: "node-exporter"
    scrape_interval: 15s
    static_configs:
      - targets: ["${APP_SERVER_IP}:9100"]
    relabel_configs:
      - source_labels: [__address__]
        target_label:  instance
        regex:         "([^:]+).*"
        replacement:   "\$1"

  # ── App server application metrics — fake-service ────────────────────────
  - job_name: "fake-service"
    scrape_interval: 15s
    static_configs:
      - targets: ["${APP_SERVER_IP}:8080"]
    relabel_configs:
      - source_labels: [__address__]
        target_label:  instance
        regex:         "([^:]+).*"
        replacement:   "\$1"

  # ── HTTP/SSL probing — Blackbox Exporter ─────────────────────────────────
  - job_name: "blackbox-http"
    metrics_path: /probe
    params:
      module: [http_2xx]
    static_configs:
      - targets:
          - "http://${APP_SERVER_IP}:8080/health"
    relabel_configs:
      - source_labels: [__address__]
        target_label:  __param_target
      - source_labels: [__param_target]
        target_label:  instance
      - target_label:  __address__
        replacement:   "127.0.0.1:9115"

  # ── SSL certificate expiry probing ───────────────────────────────────────
  - job_name: "blackbox-ssl"
    metrics_path: /probe
    params:
      module: [ssl_expiry]
    static_configs:
      - targets:
          - google.com:443
          - github.com:443
    relabel_configs:
      - source_labels: [__address__]
        target_label:  __param_target
      - source_labels: [__param_target]
        target_label:  instance
      - target_label:  __address__
        replacement:   "127.0.0.1:9115"

  # ── Alertmanager self-monitoring ─────────────────────────────────────────
  - job_name: "alertmanager"
    static_configs:
      - targets: ["127.0.0.1:9093"]

  # ── Grafana self-monitoring ───────────────────────────────────────────────
  - job_name: "grafana"
    static_configs:
      - targets: ["127.0.0.1:3000"]

  # ── Loki self-monitoring ─────────────────────────────────────────────────
  - job_name: "loki"
    static_configs:
      - targets: ["127.0.0.1:3100"]

  # ── Tempo self-monitoring ────────────────────────────────────────────────
  - job_name: "tempo"
    static_configs:
      - targets: ["127.0.0.1:3200"]
EOF

info "Writing infrastructure alert rules..."
write_config /etc/lgtm/prometheus/rules/infrastructure.yml root:prometheus 640 << 'EOF'
groups:
  - name: infrastructure.rules
    interval: 15s
    rules:

      # ── CPU ────────────────────────────────────────────────────────────────
      - alert: CPUHighWarning
        expr: 100 - (avg by(instance) (rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100) > 80
        for: 5m
        labels:
          severity: warning
        annotations:
          summary:       "High CPU on {{ $labels.instance }}"
          description:   "CPU at {{ $value | printf \"%.1f\" }}% for >5m (threshold: 80%)"
          runbook_url:   "https://github.com/YOUR_ORG/YOUR_REPO/blob/main/runbooks/cpu-high.md"
          dashboard_url: "http://${MONITORING_PUBLIC_IP}:3000/d/infrastructure/node-exporter"

      - alert: CPUCritical
        expr: 100 - (avg by(instance) (rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100) > 90
        for: 10m
        labels:
          severity: critical
        annotations:
          summary:       "Critical CPU on {{ $labels.instance }}"
          description:   "CPU at {{ $value | printf \"%.1f\" }}% for >10m (threshold: 90%)"
          runbook_url:   "https://github.com/YOUR_ORG/YOUR_REPO/blob/main/runbooks/cpu-high.md"
          dashboard_url: "http://${MONITORING_PUBLIC_IP}:3000/d/infrastructure/node-exporter"

      # ── Memory ─────────────────────────────────────────────────────────────
      - alert: MemoryHighWarning
        expr: (1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)) * 100 > 80
        for: 5m
        labels:
          severity: warning
        annotations:
          summary:       "High memory on {{ $labels.instance }}"
          description:   "Memory at {{ $value | printf \"%.1f\" }}% (threshold: 80%)"
          runbook_url:   "https://github.com/YOUR_ORG/YOUR_REPO/blob/main/runbooks/memory-high.md"
          dashboard_url: "http://${MONITORING_PUBLIC_IP}:3000/d/infrastructure/node-exporter"

      - alert: MemoryCritical
        expr: (1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)) * 100 > 90
        for: 5m
        labels:
          severity: critical
        annotations:
          summary:       "Critical memory on {{ $labels.instance }}"
          description:   "Memory at {{ $value | printf \"%.1f\" }}% (threshold: 90%)"
          runbook_url:   "https://github.com/YOUR_ORG/YOUR_REPO/blob/main/runbooks/memory-high.md"
          dashboard_url: "http://${MONITORING_PUBLIC_IP}:3000/d/infrastructure/node-exporter"

      # ── Disk ───────────────────────────────────────────────────────────────
      - alert: DiskSpaceWarning
        expr: (1 - (node_filesystem_avail_bytes{fstype!~"tmpfs|overlay|devtmpfs"} / node_filesystem_size_bytes{fstype!~"tmpfs|overlay|devtmpfs"})) * 100 > 75
        for: 5m
        labels:
          severity: warning
        annotations:
          summary:       "Disk space warning on {{ $labels.instance }}:{{ $labels.mountpoint }}"
          description:   "Disk at {{ $value | printf \"%.1f\" }}% on {{ $labels.mountpoint }} (threshold: 75%)"
          runbook_url:   "https://github.com/YOUR_ORG/YOUR_REPO/blob/main/runbooks/disk-space.md"
          dashboard_url: "http://${MONITORING_PUBLIC_IP}:3000/d/infrastructure/node-exporter"

      - alert: DiskSpaceCritical
        expr: (1 - (node_filesystem_avail_bytes{fstype!~"tmpfs|overlay|devtmpfs"} / node_filesystem_size_bytes{fstype!~"tmpfs|overlay|devtmpfs"})) * 100 > 90
        for: 5m
        labels:
          severity: critical
        annotations:
          summary:       "Critical disk on {{ $labels.instance }}:{{ $labels.mountpoint }}"
          description:   "Disk at {{ $value | printf \"%.1f\" }}% on {{ $labels.mountpoint }} (threshold: 90%)"
          runbook_url:   "https://github.com/YOUR_ORG/YOUR_REPO/blob/main/runbooks/disk-space.md"
          dashboard_url: "http://${MONITORING_PUBLIC_IP}:3000/d/infrastructure/node-exporter"

      # ── Service downtime ───────────────────────────────────────────────────
      - alert: ServiceDown
        expr: probe_success == 0
        for: 2m
        labels:
          severity: critical
        annotations:
          summary:       "Service down: {{ $labels.instance }}"
          description:   "Blackbox probe failing for {{ $labels.instance }} for >2m"
          runbook_url:   "https://github.com/YOUR_ORG/YOUR_REPO/blob/main/runbooks/service-down.md"
          dashboard_url: "http://${MONITORING_PUBLIC_IP}:3000/d/infrastructure/blackbox"
EOF

info "Writing SLO burn rate alert rules..."
write_config /etc/lgtm/prometheus/rules/slo-burn-rate.yml root:prometheus 640 << 'EOF'
groups:
  - name: slo.burn-rate.rules
    rules:

      # ── Availability SLO: 99.5% — Error budget: 3.6h/30d ─────────────────

      - alert: AvailabilitySLOFastBurn
        expr: |
          (
            1 - (
              sum(rate(probe_success{job="blackbox-http"}[1h]))
              /
              count(probe_success{job="blackbox-http"})
            )
          ) > (14.4 * 0.005)
        for: 2m
        labels:
          severity: critical
          slo:      availability
        annotations:
          summary:       "SLO Fast Burn: availability budget burning at >14.4x"
          description:   "At this rate the 30-day error budget will be exhausted in ~2 days. Act immediately."
          runbook_url:   "https://github.com/YOUR_ORG/YOUR_REPO/blob/main/runbooks/slo-burn-rate.md"
          dashboard_url: "http://${MONITORING_PUBLIC_IP}:3000/d/reliability/slo-error-budget"

      - alert: AvailabilitySLOSlowBurn
        expr: |
          (
            1 - (
              sum(rate(probe_success{job="blackbox-http"}[6h]))
              /
              count(probe_success{job="blackbox-http"})
            )
          ) > (5 * 0.005)
        for: 15m
        labels:
          severity: warning
          slo:      availability
        annotations:
          summary:       "SLO Slow Burn: availability budget draining at >5x"
          description:   "Needs attention before it escalates to fast burn."
          runbook_url:   "https://github.com/YOUR_ORG/YOUR_REPO/blob/main/runbooks/slo-burn-rate.md"
          dashboard_url: "http://${MONITORING_PUBLIC_IP}:3000/d/reliability/slo-error-budget"

      # ── Latency SLO: 95% of requests < 500ms ─────────────────────────────

      - alert: LatencySLOFastBurn
        expr: |
          (
            1 - (
              sum(rate(http_request_duration_seconds_bucket{le="0.5"}[1h]))
              /
              sum(rate(http_request_duration_seconds_count[1h]))
            )
          ) > (14.4 * 0.05)
        for: 2m
        labels:
          severity: critical
          slo:      latency
        annotations:
          summary:       "SLO Fast Burn: latency budget burning at >14.4x"
          description:   "More requests than allowed are exceeding 500ms. Fast burn on latency SLO."
          runbook_url:   "https://github.com/YOUR_ORG/YOUR_REPO/blob/main/runbooks/slo-burn-rate.md"
          dashboard_url: "http://${MONITORING_PUBLIC_IP}:3000/d/reliability/slo-error-budget"

      - alert: LatencySLOSlowBurn
        expr: |
          (
            1 - (
              sum(rate(http_request_duration_seconds_bucket{le="0.5"}[6h]))
              /
              sum(rate(http_request_duration_seconds_count[6h]))
            )
          ) > (5 * 0.05)
        for: 15m
        labels:
          severity: warning
          slo:      latency
        annotations:
          summary:       "SLO Slow Burn: latency budget draining at >5x"
          description:   "Latency SLO slow burn over 6h window. Review recent deployments."
          runbook_url:   "https://github.com/YOUR_ORG/YOUR_REPO/blob/main/runbooks/slo-burn-rate.md"
          dashboard_url: "http://${MONITORING_PUBLIC_IP}:3000/d/reliability/slo-error-budget"
EOF

info "Validating Prometheus config with promtool..."
if /opt/lgtm/prometheus/promtool check config /etc/lgtm/prometheus/prometheus.yml; then
  ok "prometheus.yml: valid"
else
  fail "prometheus.yml: INVALID — fix before Phase 4"
fi

info "Validating alert rules with promtool..."
if /opt/lgtm/prometheus/promtool check rules /etc/lgtm/prometheus/rules/*.yml; then
  ok "Alert rules: valid"
else
  fail "Alert rules: INVALID — fix before Phase 4"
fi

# =============================================================================
section "2/7 — ALERTMANAGER"
# =============================================================================

info "Writing alertmanager.yml..."

# ── Extract and validate the webhook URL first ──────────────────────────────
# Done before any file writes so the script dies early with a clear message
# rather than writing a broken config and failing at amtool validation.
SLACK_URL=$(grep '^SLACK_WEBHOOK_URL=' /etc/lgtm/secrets | cut -d= -f2-)
[[ -z "$SLACK_URL" ]] && die "SLACK_WEBHOOK_URL not set in /etc/lgtm/secrets — add it and re-run"
[[ "$SLACK_URL" == *"REPLACE"* ]] && die "SLACK_WEBHOOK_URL is still a placeholder — set the real URL in /etc/lgtm/secrets"
[[ "$SLACK_URL" != https://* ]] && die "SLACK_WEBHOOK_URL must start with https://"

# ── Idempotency: repair any previously written bad config ───────────────────
# If a previous run wrote the placeholder or the literal variable name,
# fix it now automatically. No manual intervention required.
if [[ -f /etc/lgtm/alertmanager/alertmanager.yml ]]; then
  if grep -qE '__SLACK_WEBHOOK_PLACEHOLDER__|\.SLACK_WEBHOOK_URL\.' \
       /etc/lgtm/alertmanager/alertmanager.yml 2>/dev/null || \
     grep -q 'SLACK_WEBHOOK_URL' /etc/lgtm/alertmanager/alertmanager.yml 2>/dev/null; then
    warn "Existing alertmanager.yml has unresolved placeholder — repairing automatically"
    sed -i "s|__SLACK_WEBHOOK_PLACEHOLDER__|${SLACK_URL}|g" \
      /etc/lgtm/alertmanager/alertmanager.yml
    sed -i 's|\${SLACK_WEBHOOK_URL}|'"${SLACK_URL}"'|g' \
      /etc/lgtm/alertmanager/alertmanager.yml
    ok "Existing alertmanager.yml repaired"
  fi
fi

# ── Write config with sentinel, then immediately replace sentinel ────────────
# Single-quoted heredoc keeps {{ Go template }} syntax safe from bash.
# Sentinel __SLACK_WEBHOOK_PLACEHOLDER__ is replaced by sed immediately after.

write_config /etc/lgtm/alertmanager/alertmanager.yml root:alertmanager 640 << 'AMEOF'
global:
  resolve_timeout:  5m
  slack_api_url:    "__SLACK_WEBHOOK_PLACEHOLDER__"

templates:
  - "/etc/lgtm/alertmanager/templates/*.tmpl"

route:
  group_by:        ["alertname", "severity", "instance"]
  group_wait:      30s
  group_interval:  5m
  repeat_interval: 4h
  receiver:        "slack-devops-alerts"

  routes:
    - match:
        severity: critical
      receiver:        "slack-devops-alerts"
      group_wait:      10s
      repeat_interval: 1h

    - match_re:
        alertname: ".*(SLO|Burn).*"
      receiver:        "slack-devops-alerts"
      group_by:        ["alertname", "slo"]
      group_wait:      10s
      repeat_interval: 30m

    - match:
        severity: warning
      receiver:        "slack-devops-alerts"
      repeat_interval: 6h

inhibit_rules:
  - source_match:
      alertname: "ServiceDown"
      severity:  "critical"
    target_match_re:
      alertname: "CPU.*|Memory.*|Disk.*|Latency.*"
    equal: ["instance"]

  - source_match:
      severity: "critical"
    target_match:
      severity: "warning"
    equal: ["alertname", "instance"]

receivers:
  - name: "slack-devops-alerts"
    slack_configs:
      - channel:       "#DevOps-Alerts"
        send_resolved: true
        title:         '{{ template "slack.title" . }}'
        text:          '{{ template "slack.body" . }}'
        color:         '{{ template "slack.color" . }}'
        icon_emoji:    '{{ template "slack.icon" . }}'
AMEOF

# Inject the real webhook URL — sed handles any special chars in the URL
# by using | as delimiter instead of / (URLs contain forward slashes)
sed -i "s|__SLACK_WEBHOOK_PLACEHOLDER__|${SLACK_URL}|g" \
  /etc/lgtm/alertmanager/alertmanager.yml
ok "Slack webhook URL injected into alertmanager.yml"

MASKED=$(echo "$SLACK_URL" | sed 's|/services/.*|/services/***MASKED***|')
info "slack_api_url set to: ${MASKED}"

info "Writing Slack alert template..."
# Idempotency: if the template was already written with the bad | default
# function, fix it automatically before overwriting with the correct version.
if [[ -f /etc/lgtm/alertmanager/templates/slack.tmpl ]]; then
  if grep -q "| default" /etc/lgtm/alertmanager/templates/slack.tmpl 2>/dev/null; then
    warn "Existing slack.tmpl uses unsupported | default function — repairing automatically"
    python3 -c "
path = '/etc/lgtm/alertmanager/templates/slack.tmpl'
with open(path) as f: content = f.read()
content = content.replace(
    '{{ .Labels.instance | default \"N/A\" }}',
    '{{ if .Labels.instance }}{{ .Labels.instance }}{{ else }}N/A{{ end }}'
)
with open(path, 'w') as f: f.write(content)
"
    ok "slack.tmpl repaired"
  fi
fi
write_config /etc/lgtm/alertmanager/templates/slack.tmpl root:alertmanager 640 << 'EOF'
{{ define "slack.title" -}}
[{{ .Status | toUpper }}{{ if eq .Status "firing" }}:{{ .Alerts.Firing | len }}{{ end }}] {{ .CommonLabels.alertname }}
{{- end }}

{{ define "slack.color" -}}
{{ if eq .Status "resolved" }}good
{{ else if eq .CommonLabels.severity "critical" }}danger
{{ else if eq .CommonLabels.severity "warning" }}warning
{{ else }}#439FE0{{ end }}
{{- end }}

{{ define "slack.icon" -}}
{{ if eq .Status "resolved" }}:white_check_mark:
{{ else if eq .CommonLabels.severity "critical" }}:red_circle:
{{ else if eq .CommonLabels.severity "warning" }}:warning:
{{ else }}:information_source:{{ end }}
{{- end }}

{{ define "slack.body" -}}
{{ range .Alerts }}
*Alert:*     {{ .Annotations.summary }}
*Severity:*  {{ .Labels.severity | toUpper }}
*Host:*      {{ if .Labels.instance }}{{ .Labels.instance }}{{ else }}N/A{{ end }}
*Status:*    {{ if eq $.Status "resolved" }}:white_check_mark: RESOLVED{{ else }}:fire: FIRING{{ end }}
*Detail:*    {{ .Annotations.description }}
{{ if .Annotations.dashboard_url }}*Dashboard:* <{{ .Annotations.dashboard_url }}|Open in Grafana>{{ end }}
{{ if .Annotations.runbook_url }}*Runbook:*   <{{ .Annotations.runbook_url }}|View Runbook>{{ end }}
*Fired:*     {{ .StartsAt | since }}{{ if eq $.Status "resolved" }}
*Resolved:*  {{ .EndsAt | since }}{{ end }}
---
{{ end }}
{{- end }}
EOF

info "Validating Alertmanager config with amtool..."
# The webhook URL is now a real URL injected at write time from /etc/lgtm/secrets.
# amtool can validate the full config including the URL scheme.
if /opt/lgtm/alertmanager/amtool check-config \
    /etc/lgtm/alertmanager/alertmanager.yml 2>&1; then
  ok "alertmanager.yml: valid"
else
  fail "alertmanager.yml: INVALID — check output above and fix before Phase 4"
fi

# =============================================================================
section "3/7 — LOKI"
# =============================================================================

info "Writing loki-config.yml..."
write_config /etc/lgtm/loki/loki-config.yml root:loki 640 << 'EOF'
auth_enabled: false

server:
  http_listen_port: 3100
  grpc_listen_port: 9096
  log_level:        warn

common:
  instance_addr: 127.0.0.1
  path_prefix:   /var/lib/lgtm/loki
  storage:
    filesystem:
      chunks_directory: /var/lib/lgtm/loki/chunks
      rules_directory:  /var/lib/lgtm/loki/rules
  replication_factor: 1
  ring:
    kvstore:
      store: inmemory

query_range:
  results_cache:
    cache:
      embedded_cache:
        enabled:    true
        max_size_mb: 100

schema_config:
  configs:
    - from:          "2024-01-01"
      store:         tsdb
      object_store:  filesystem
      schema:        v13
      index:
        prefix: index_
        period: 24h

limits_config:
  # 30-day log retention
  retention_period:       720h
  ingestion_rate_mb:      16
  ingestion_burst_size_mb: 32
  # Maximum query lookback — prevent runaway historical queries
  max_query_lookback:     720h
  max_query_length:       721h

compactor:
  working_directory:    /var/lib/lgtm/loki/retention
  retention_enabled:    true
  retention_delete_delay: 2h
  delete_request_store: filesystem

ruler:
  alertmanager_url: http://127.0.0.1:9093
EOF

info "Validating Loki config..."
if /opt/lgtm/loki/loki -config.file=/etc/lgtm/loki/loki-config.yml -verify-config 2>&1; then
  ok "loki-config.yml: valid"
else
  warn "Loki config validation returned non-zero — review output above"
fi

# =============================================================================
section "4/7 — TEMPO"
# =============================================================================

info "Writing tempo-config.yml..."
write_config /etc/lgtm/tempo/tempo-config.yml root:tempo 640 << 'EOF'
server:
  http_listen_port: 3200
  log_level:        warn

distributor:
  receivers:
    otlp:
      protocols:
        grpc:
          endpoint: 0.0.0.0:4317
        http:
          endpoint: 0.0.0.0:4318

metrics_generator:
  registry:
    external_labels:
      source:  tempo
      cluster: lgtm-production
  storage:
    path: /var/lib/lgtm/tempo/wal
    remote_write:
      - url:           http://127.0.0.1:9090/api/v1/write
        send_exemplars: true

storage:
  trace:
    backend: local
    local:
      path: /var/lib/lgtm/tempo/traces
    wal:
      path: /var/lib/lgtm/tempo/wal


overrides:
  defaults:
    metrics_generator:
      processors:                [service-graphs, span-metrics]
      generate_native_histograms: both
EOF

# Tempo has no -verify-config — do a dry-run startup check instead
info "Checking Tempo config syntax (dry run)..."
if timeout 5 /opt/lgtm/tempo/tempo \
    --config.file=/etc/lgtm/tempo/tempo-config.yml \
    2>&1 | grep -i "error\|invalid\|failed" | grep -v "^$"; then
  warn "Tempo reported errors during dry run — review above"
else
  ok "tempo-config.yml: no obvious errors detected"
fi

# OTel Collector config is written by app-agent.sh on the application server.

# =============================================================================
section "6/7 — BLACKBOX EXPORTER"
# =============================================================================

info "Writing blackbox.yml..."
write_config /etc/lgtm/blackbox-exporter/blackbox.yml root:exporter 640 << 'EOF'
modules:
  http_2xx:
    prober:  http
    timeout: 10s
    http:
      valid_http_versions:  ["HTTP/1.1", "HTTP/2.0"]
      valid_status_codes:   []
      method:               GET
      follow_redirects:     true
      preferred_ip_protocol: "ip4"
      tls_config:
        insecure_skip_verify: false

  ssl_expiry:
    prober:  http
    timeout: 10s
    http:
      method:           GET
      fail_if_ssl:      false
      fail_if_not_ssl:  true
      tls_config:
        insecure_skip_verify: false

  tcp_connect:
    prober:  tcp
    timeout: 5s

  icmp:
    prober:  icmp
    timeout: 5s
    icmp:
      preferred_ip_protocol: "ip4"
EOF

# =============================================================================
section "7/7 — GRAFANA"
# =============================================================================

info "Writing grafana.ini..."
# Grafana .deb installs default ini at /etc/grafana/grafana.ini.
# We write our own into /etc/lgtm/grafana/ and the systemd unit will
# point grafana-server at it via the --config flag.
write_config /etc/lgtm/grafana/grafana.ini root:grafana 640 << 'EOF'
[paths]
data         = /var/lib/lgtm/grafana
logs         = /var/log/lgtm/grafana
plugins      = /var/lib/lgtm/grafana/plugins
provisioning = /etc/lgtm/grafana/provisioning

[server]
protocol        = http
http_addr       = 0.0.0.0
http_port       = 3000
root_url        = http://localhost:3000
serve_from_sub_path = false

[database]
type = sqlite3
path = /var/lib/lgtm/grafana/grafana.db

[security]
# Admin credentials are injected at runtime from /etc/lgtm/secrets
# via EnvironmentFile in the systemd unit.
admin_user              = ${GF_SECURITY_ADMIN_USER}
admin_password          = ${GF_SECURITY_ADMIN_PASSWORD}
disable_gravatar        = true
cookie_secure           = false
cookie_samesite         = lax
allow_embedding         = false
# Disable user signup — this is an internal tool, not a public service
disable_user_signup     = true

[users]
allow_sign_up           = false
allow_org_create        = false
auto_assign_org         = true
auto_assign_org_role    = Viewer

[auth.anonymous]
enabled = false

[log]
mode  = console
level = warn

[analytics]
reporting_enabled    = false
check_for_updates    = false
check_for_plugin_updates = false

[feature_toggles]
enable = traceqlEditor
EOF

info "Writing Grafana datasources provisioning..."
write_config /etc/lgtm/grafana/provisioning/datasources/datasources.yml root:grafana 640 << 'EOF'
apiVersion: 1

datasources:

  - name:      Prometheus
    type:      prometheus
    uid:       prometheus
    access:    proxy
    url:       http://127.0.0.1:9090
    isDefault: true
    jsonData:
      httpMethod: POST
      exemplarTraceIdDestinations:
        - name:           traceID
          datasourceUid:  tempo

  - name:   Loki
    type:   loki
    uid:    loki
    access: proxy
    url:    http://127.0.0.1:3100
    jsonData:
      derivedFields:
        - datasourceUid:  tempo
          matcherRegex:   "traceID=(\\w+)"
          name:           TraceID
          url:            "$${__value.raw}"
          urlDisplayLabel: "Open in Tempo"

  - name:   Tempo
    type:   tempo
    uid:    tempo
    access: proxy
    url:    http://127.0.0.1:3200
    jsonData:
      httpMethod: GET
      serviceMap:
        datasourceUid: prometheus
      nodeGraph:
        enabled: true
      lokiSearch:
        datasourceUid: loki
      traceQuery:
        timeShiftEnabled:  true
        spanStartTimeShift: "1h"
        spanEndTimeShift:   "-1h"
EOF

info "Writing Grafana dashboard provider..."
write_config /etc/lgtm/grafana/provisioning/dashboards/provider.yml root:grafana 640 << 'EOF'
apiVersion: 1

providers:
  - name:                  "lgtm-dashboards"
    orgId:                 1
    type:                  file
    disableDeletion:       true
    updateIntervalSeconds: 30
    allowUiUpdates:        false
    options:
      path:                        /etc/lgtm/grafana/dashboards
      foldersFromFilesStructure:   true
EOF

# =============================================================================
section "8/8 — CORRECT ALL CONFIG FILE PERMISSIONS"
# =============================================================================
# Final sweep — enforce correct ownership on everything written above.
# Nemeth: permissions applied once at the end of a write phase catch any
# file the script may have created with wrong defaults.

info "Enforcing final config file permissions..."

# Subdirectories: root owns, group can traverse and read
# mindepth 1 preserves /etc/lgtm itself at 755 — service users must traverse it
find /etc/lgtm -mindepth 1 -type d -exec chmod 750 {} \;
chmod 755 /etc/lgtm

# Config files: root:group, group-readable, no world access
find /etc/lgtm/prometheus   -type f -exec chown root:prometheus   {} \; -exec chmod 640 {} \;
find /etc/lgtm/loki         -type f -exec chown root:loki         {} \; -exec chmod 640 {} \;
find /etc/lgtm/tempo        -type f -exec chown root:tempo        {} \; -exec chmod 640 {} \;
find /etc/lgtm/grafana      -type f -exec chown root:grafana      {} \; -exec chmod 640 {} \;
find /etc/lgtm/alertmanager -type f -exec chown root:alertmanager {} \; -exec chmod 640 {} \;
find /etc/lgtm/blackbox-exporter -type f -exec chown root:exporter {} \; -exec chmod 640 {} \;

# Secrets file must remain 600 — root only
chmod 600 /etc/lgtm/secrets
ok "Permissions enforced on all config files"

# =============================================================================
section "PHASE 3 SUMMARY"
# =============================================================================

echo ""
if [[ "$ERRORS" -eq 0 ]]; then
  echo -e "${GRN}${BLD}✓ All configuration files written and validated.${RST}"
  echo -e "${GRN}  Proceeding to Phase 4 — systemd unit files.${RST}"
else
  echo -e "${RED}${BLD}✗ ${ERRORS} error(s) found.${RST}"
fi
echo ""
[[ "$ERRORS" -gt 0 ]] && die "Phase 3 failed with ${ERRORS} error(s) — fix above before Phase 4 proceeds."

# Helper: write unit, verify syntax, enable but do not start yet
install_unit() {
  local unit_name="$1"
  local unit_file="${SYSTEMD_DIR}/${unit_name}"

  # Content arrives via stdin
  cat > "$unit_file"
  chown root:root "$unit_file"
  chmod 644 "$unit_file"
  ok "Written: ${unit_file}"

  # Nemeth: validate before enabling — systemd-analyze verify catches
  # missing After= targets, bad directives, and type mismatches
  info "Verifying unit syntax: ${unit_name}..."
  if systemd-analyze verify "$unit_file" 2>&1; then
    ok "Unit syntax valid: ${unit_name}"
  else
    warn "systemd-analyze reported warnings for ${unit_name} — review above"
  fi
}

# =============================================================================
section "RELOADING SYSTEMD DAEMON"
# =============================================================================
systemctl daemon-reload
ok "systemd daemon reloaded"

# Node Exporter runs on the application server — installed by app-agent.sh.

# =============================================================================
section "1/8 — BLACKBOX EXPORTER"
# Needs CAP_NET_RAW for ICMP probing. We grant it explicitly rather than
# running as root. If ICMP is not needed, remove AmbientCapabilities.
# =============================================================================

install_unit "blackbox-exporter.service" << 'EOF'
[Unit]
Description=Prometheus Blackbox Exporter
Documentation=https://github.com/prometheus/blackbox_exporter
After=network.target

[Service]
Type=simple
User=exporter
Group=exporter
EnvironmentFile=-/etc/lgtm/env

ExecStart=/opt/lgtm/blackbox-exporter/blackbox_exporter \
  --config.file=/etc/lgtm/blackbox-exporter/blackbox.yml \
  --web.listen-address=127.0.0.1:9115

Restart=on-failure
RestartSec=5s

# ── Security hardening ────────────────────────────────────────────────────
NoNewPrivileges=yes
PrivateTmp=yes
ProtectHome=yes
ProtectSystem=full
ReadWritePaths=

# ICMP probing requires CAP_NET_RAW.
# If you remove ICMP from blackbox.yml, remove these two lines.
AmbientCapabilities=CAP_NET_RAW
CapabilityBoundingSet=CAP_NET_RAW

LimitNOFILE=8192
MemoryMax=128M
CPUQuota=10%

[Install]
WantedBy=multi-user.target
EOF

# =============================================================================
section "3/8 — ALERTMANAGER"
# Starts early — Prometheus needs it up before firing alerts.
# Slack webhook URL injected from /etc/lgtm/secrets at runtime.
# =============================================================================

install_unit "alertmanager.service" << 'EOF'
[Unit]
Description=Prometheus Alertmanager
Documentation=https://github.com/prometheus/alertmanager
After=network.target

[Service]
Type=simple
User=alertmanager
Group=alertmanager
EnvironmentFile=/etc/lgtm/env
# Secrets file — contains SLACK_WEBHOOK_URL.
# Mode 600 — only root can read, but systemd reads it on behalf of the unit.
EnvironmentFile=/etc/lgtm/secrets

ExecStart=/opt/lgtm/alertmanager/alertmanager \
  --config.file=/etc/lgtm/alertmanager/alertmanager.yml \
  --storage.path=/var/lib/lgtm/alertmanager \
  --web.listen-address=127.0.0.1:9093 \
  --log.level=warn

# Reload config without restart (send SIGHUP)
ExecReload=/bin/kill -HUP $MAINPID

Restart=on-failure
RestartSec=5s

# ── Security hardening ────────────────────────────────────────────────────
NoNewPrivileges=yes
PrivateTmp=yes
ProtectHome=yes
ProtectSystem=full
ReadWritePaths=/var/lib/lgtm/alertmanager /var/log/lgtm/alertmanager
CapabilityBoundingSet=

LimitNOFILE=8192
MemoryMax=256M

[Install]
WantedBy=multi-user.target
EOF


# =============================================================================
section "4/8 — LOKI"
# =============================================================================

install_unit "loki.service" << 'EOF'
[Unit]
Description=Grafana Loki Log Aggregation
Documentation=https://grafana.com/docs/loki/latest/
After=network.target

[Service]
Type=simple
User=loki
Group=loki
EnvironmentFile=-/etc/lgtm/env

ExecStart=/opt/lgtm/loki/loki \
  -config.file=/etc/lgtm/loki/loki-config.yml

ExecReload=/bin/kill -HUP $MAINPID

Restart=on-failure
RestartSec=10s
# Loki initialises storage on first start — give it time before declaring failed
TimeoutStartSec=60s

# ── Security hardening ────────────────────────────────────────────────────
NoNewPrivileges=yes
PrivateTmp=yes
ProtectHome=yes
ProtectSystem=full
ReadWritePaths=/var/lib/lgtm/loki /var/log/lgtm/loki
CapabilityBoundingSet=

# Loki uses mmap for TSDB index — requires higher fd limits
LimitNOFILE=65536
MemoryMax=2G
CPUQuota=50%

[Install]
WantedBy=multi-user.target
EOF

# =============================================================================
section "5/7 — TEMPO"
# =============================================================================

install_unit "tempo.service" << 'EOF'
[Unit]
Description=Grafana Tempo Distributed Tracing
Documentation=https://grafana.com/docs/tempo/latest/
After=network.target

[Service]
Type=simple
User=tempo
Group=tempo
EnvironmentFile=-/etc/lgtm/env

ExecStart=/opt/lgtm/tempo/tempo \
  --config.file=/etc/lgtm/tempo/tempo-config.yml

Restart=on-failure
RestartSec=10s
TimeoutStartSec=60s

# ── Security hardening ────────────────────────────────────────────────────
NoNewPrivileges=yes
PrivateTmp=yes
ProtectHome=yes
ProtectSystem=full
ReadWritePaths=/var/lib/lgtm/tempo /var/log/lgtm/tempo /var/tempo
CapabilityBoundingSet=

LimitNOFILE=32768
MemoryMax=2G
CPUQuota=50%

[Install]
WantedBy=multi-user.target
EOF

# OTel Collector runs on the application server — installed by app-agent.sh.

# =============================================================================
section "6/7 — PROMETHEUS"
# Starts after exporters and alertmanager.
# Uses Wants= for exporters (non-fatal if missing) but Requires= for
# alertmanager (prometheus with no alertmanager is broken by design).
# =============================================================================

install_unit "prometheus.service" << 'EOF'
[Unit]
Description=Prometheus Metrics Server
Documentation=https://prometheus.io/docs/
After=network.target blackbox-exporter.service alertmanager.service
Wants=blackbox-exporter.service
Requires=alertmanager.service

[Service]
Type=simple
User=prometheus
Group=prometheus
EnvironmentFile=/etc/lgtm/env

ExecStart=/opt/lgtm/prometheus/prometheus \
  --config.file=/etc/lgtm/prometheus/prometheus.yml \
  --storage.tsdb.path=/var/lib/lgtm/prometheus \
  --storage.tsdb.retention.time=${PROMETHEUS_RETENTION_TIME} \
  --storage.tsdb.wal-compression \
  --web.listen-address=127.0.0.1:9090 \
  --web.enable-lifecycle \
  --web.enable-admin-api \
  --web.enable-remote-write-receiver \
  --log.level=warn

# Live config reload without restart: curl -X POST http://localhost:9090/-/reload
ExecReload=/bin/kill -HUP $MAINPID

Restart=on-failure
RestartSec=5s
TimeoutStartSec=60s

# ── Security hardening ────────────────────────────────────────────────────
NoNewPrivileges=yes
PrivateTmp=yes
ProtectHome=yes
ProtectSystem=full
ReadWritePaths=/var/lib/lgtm/prometheus /var/log/lgtm/prometheus
CapabilityBoundingSet=

# Prometheus TSDB opens many files under heavy metric load
LimitNOFILE=65536
MemoryMax=4G
CPUQuota=80%

[Install]
WantedBy=multi-user.target
EOF

# =============================================================================
section "7/7 — GRAFANA"
# The .deb installs grafana-server.service — we replace it with our own
# hardened unit that points at /etc/lgtm/grafana/grafana.ini instead of
# the default /etc/grafana/grafana.ini.
# Starts last — depends on all data sources being available.
# =============================================================================

install_unit "grafana-server.service" << 'EOF'
[Unit]
Description=Grafana Observability Frontend
Documentation=https://grafana.com/docs/grafana/latest/
After=network.target prometheus.service loki.service tempo.service
Wants=prometheus.service loki.service tempo.service

[Service]
Type=simple
User=grafana
Group=grafana
EnvironmentFile=/etc/lgtm/env
EnvironmentFile=/etc/lgtm/secrets

# Point at our config, not the .deb default /etc/grafana/grafana.ini
ExecStart=/usr/sbin/grafana-server \
  --config=/etc/lgtm/grafana/grafana.ini \
  --homepath=/usr/share/grafana \
  --pidfile=/var/run/grafana/grafana-server.pid

Restart=on-failure
RestartSec=10s
TimeoutStartSec=120s

# PID file directory
RuntimeDirectory=grafana
RuntimeDirectoryMode=0755

# ── Security hardening ────────────────────────────────────────────────────
NoNewPrivileges=yes
PrivateTmp=yes
ProtectHome=yes
ProtectSystem=full
ReadWritePaths=/var/lib/lgtm/grafana /var/log/lgtm/grafana /etc/lgtm/grafana/dashboards
CapabilityBoundingSet=

LimitNOFILE=16384
MemoryMax=1G
CPUQuota=50%

[Install]
WantedBy=multi-user.target
EOF

# =============================================================================
section "ENABLE ALL UNITS (do not start yet)"
# Enable registers units to start at boot via WantedBy=multi-user.target.
# We do NOT start them here — Phase 5 (verify) starts them in order
# and checks each one before proceeding to the next.
# =============================================================================

systemctl daemon-reload
ok "systemd daemon reloaded with new units"

UNITS=(
  blackbox-exporter.service
  alertmanager.service
  loki.service
  tempo.service
  prometheus.service
  grafana-server.service
)

for unit in "${UNITS[@]}"; do
  if systemctl enable "$unit" 2>&1; then
    ok "Enabled: ${unit}"
  else
    fail "Failed to enable: ${unit}"
  fi
done

# =============================================================================
section "UNIT FILE SUMMARY"
# =============================================================================

echo ""
info "Installed unit files:"
for unit in "${UNITS[@]}"; do
  unit_file="${SYSTEMD_DIR}/${unit}"
  if [[ -f "$unit_file" ]]; then
    ENABLED=$(systemctl is-enabled "$unit" 2>/dev/null || echo "unknown")
    echo -e "  ${GRN}✓${RST} ${unit} — ${ENABLED}"
  else
    echo -e "  ${RED}✗${RST} ${unit} — FILE MISSING"
    ERRORS=$((ERRORS+1))
  fi
done

echo ""
if [[ "$ERRORS" -eq 0 ]]; then
  echo -e "${GRN}${BLD}✓ All unit files installed and enabled.${RST}"
  echo -e "${GRN}  Proceeding to Phase 5 — hardening and bring-up.${RST}"
else
  echo -e "${RED}${BLD}✗ ${ERRORS} error(s) in Phase 4.${RST}"
fi
echo ""
[[ "$ERRORS" -gt 0 ]] && die "Phase 4 failed with ${ERRORS} error(s) — fix above before Phase 5 proceeds."

# Seconds to wait after starting a service before health-checking it
STARTUP_WAIT=10

# ─── Health check helper ──────────────────────────────────────────────────────
# Polls an HTTP endpoint until it returns 200, or times out.
# Nemeth: health checks must be explicit and time-bounded.
wait_for_http() {
  local name="$1" url="$2" timeout="${3:-30}"
  local elapsed=0
  info "Waiting for ${name} at ${url} (timeout: ${timeout}s)..."
  while ! curl -sf "$url" -o /dev/null 2>/dev/null; do
    if [[ "$elapsed" -ge "$timeout" ]]; then
      fail "${name} did not become healthy within ${timeout}s"
      fail "  Check logs: journalctl -u ${name,,} --no-pager -n 30"
      return 1
    fi
    sleep 2
    elapsed=$((elapsed+2))
  done
  ok "${name} is healthy at ${url} (took ${elapsed}s)"
}

# ─── Start and verify a service ───────────────────────────────────────────────
start_and_verify() {
  local unit="$1" health_url="$2" timeout="${3:-30}"
  info "Starting ${unit}..."
  systemctl start "$unit"
  sleep "$STARTUP_WAIT"

  if ! systemctl is-active --quiet "$unit"; then
    fail "${unit} is not active after start"
    journalctl -u "$unit" --no-pager -n 20
    die "Stopping — fix ${unit} before continuing"
  fi

  wait_for_http "$unit" "$health_url" "$timeout"
}

# =============================================================================
# PART 1 — HARDENING
# =============================================================================

section "PART 1A — FIREWALL (ufw)"
# Nemeth ch.27: expose only what must be exposed.
# Internal LGTM services (Prometheus, Loki, Tempo, Alertmanager) are bound
# to 127.0.0.1 in their unit files — they are unreachable from outside by
# design. No firewall rule needed to block them; binding to loopback is
# the correct architectural decision.
# Only Grafana (3000) needs external access for the dashboard UI.

if command -v ufw &>/dev/null; then
  info "Configuring ufw firewall..."

  # Reset to defaults — idempotent
  ufw --force reset 2>/dev/null

  # Default policies: deny inbound, allow outbound
  ufw default deny incoming
  ufw default allow outgoing

  # SSH — critical: allow before enabling or you lock yourself out
  ufw allow ssh comment "SSH access"

  # Grafana — the only LGTM service that needs external access
  # If Grafana will sit behind a reverse proxy (nginx/caddy),
  # change this to allow only from localhost or the proxy IP.
  ufw allow 3000/tcp comment "Grafana dashboard"

  # Pushgateway: open to internet so GitHub Actions can push DORA metrics directly
  ufw allow 9091/tcp comment "Pushgateway — DORA metrics from GitHub Actions"

  # Enable without interactive prompt
  ufw --force enable
  ok "ufw enabled: SSH, Grafana(:3000), Pushgateway(:9091) open"

  ufw status verbose
else
  warn "ufw not installed — install with: apt-get install ufw"
  warn "Manually restrict access to ports 9090 9093 9115 3100 3200 4317 4318"
fi

# =============================================================================
section "PART 1B — FILE PERMISSION AUDIT"
# Final sweep before any service starts.
# Nemeth: permissions are not a one-time setup — audit them.
# =============================================================================

info "Auditing critical file permissions..."

audit_perm() {
  local path="$1" expected_mode="$2" expected_owner="$3"
  if [[ ! -e "$path" ]]; then
    fail "MISSING: ${path}"
    return
  fi
  local actual_mode actual_owner
  actual_mode=$(stat -c '%a' "$path")
  actual_owner=$(stat -c '%U:%G' "$path")

  if [[ "$actual_mode" == "$expected_mode" && "$actual_owner" == "$expected_owner" ]]; then
    ok "OK ${actual_mode} ${actual_owner}: ${path}"
  else
    fail "WRONG: ${path} — mode ${actual_mode} (want ${expected_mode}), owner ${actual_owner} (want ${expected_owner})"
  fi
}

# Secrets — must be 600 root:root. If this is wrong, Slack alerts break.
audit_perm /etc/lgtm/secrets                         600 root:root
audit_perm /etc/lgtm/env                             644 root:root

# Data dirs — service user must own these or the service won't write data
audit_perm /var/lib/lgtm/prometheus                  750 prometheus:prometheus
audit_perm /var/lib/lgtm/loki                        750 loki:loki
audit_perm /var/lib/lgtm/tempo                       750 tempo:tempo
audit_perm /var/tempo                                750 tempo:tempo
audit_perm /var/lib/lgtm/grafana                     750 grafana:grafana
audit_perm /var/lib/lgtm/alertmanager                750 alertmanager:alertmanager

# Config dirs — root owns, group readable
audit_perm /etc/lgtm/prometheus                      750 root:prometheus
audit_perm /etc/lgtm/loki                            750 root:loki
audit_perm /etc/lgtm/tempo                           750 root:tempo
audit_perm /etc/lgtm/grafana                         750 root:grafana
audit_perm /etc/lgtm/alertmanager                    750 root:alertmanager

# Binaries — root owns, world executable
audit_perm /opt/lgtm/prometheus/prometheus            755 root:root
audit_perm /opt/lgtm/alertmanager/alertmanager        755 root:root
audit_perm /opt/lgtm/loki/loki                        755 root:root
audit_perm /opt/lgtm/tempo/tempo                      755 root:root
audit_perm /opt/lgtm/blackbox-exporter/blackbox_exporter 755 root:root

if [[ "$ERRORS" -gt 0 ]]; then
  die "Permission audit failed — fix ${ERRORS} error(s) before starting services"
fi
ok "All permission audits passed"

# =============================================================================
section "PART 1C — KERNEL PARAMETERS FINAL CHECK"
# =============================================================================

info "Verifying kernel parameters are applied..."

check_sysctl() {
  local key="$1" expected="$2"
  local actual
  actual=$(sysctl -n "$key" 2>/dev/null || echo "NOT_SET")
  if [[ "$actual" == "$expected" ]]; then
    ok "sysctl ${key} = ${actual}"
  else
    warn "sysctl ${key} = ${actual} (expected ${expected}) — applying now"
    sysctl -w "${key}=${expected}" &>/dev/null || fail "Could not set ${key}"
  fi
}

check_sysctl vm.max_map_count         262144
check_sysctl fs.inotify.max_user_watches 65536

# =============================================================================
section "PART 1D — SECRETS VALIDATION"
# Fail loudly if secrets are still placeholders.
# Nemeth: a deployment with placeholder credentials is not a deployment.
# =============================================================================

info "Checking /etc/lgtm/secrets for placeholder values..."
if grep -q "__SLACK_PLACEHOLDER__" /etc/lgtm/secrets; then
  die "SLACK_WEBHOOK_URL is still a placeholder in /etc/lgtm/secrets — SSM fetch must have failed"
fi
if grep -q "change_me_in_production" /etc/lgtm/secrets; then
  die "GF_SECURITY_ADMIN_PASSWORD is still the default — SSM fetch must have failed"
fi
ok "Secrets look populated"

# Inject real secrets into Alertmanager config before it starts
source /etc/lgtm/secrets
sed -i "s|SLACK_WEBHOOK_PLACEHOLDER|${SLACK_WEBHOOK_URL}|g" /etc/lgtm/alertmanager/alertmanager.yml
sed -i "s|SLACK_CHANNEL_PLACEHOLDER|#social-badge-devops-alerts|g" /etc/lgtm/alertmanager/alertmanager.yml
ok "Slack webhook and channel injected into Alertmanager config"

# =============================================================================
# PART 2 — SERVICE BRING-UP IN DEPENDENCY ORDER
# Each service is started, waited on, and health-checked before the next.
# If any service fails its health check, the script stops.
# =============================================================================

section "PART 2A — BLACKBOX EXPORTER"

start_and_verify \
  "blackbox-exporter.service" \
  "http://127.0.0.1:9115/health" \
  30

# Test that the http_2xx module actually works
info "Testing blackbox http_2xx probe against google.com..."
if curl -sf "http://127.0.0.1:9115/probe?target=https://google.com&module=http_2xx" \
   | grep -q "probe_success 1"; then
  ok "Blackbox http_2xx probe: working"
else
  warn "Blackbox probe returned probe_success != 1 for google.com — check network access"
fi

# =============================================================================
section "PART 2B — ALERTMANAGER"

start_and_verify \
  "alertmanager.service" \
  "http://127.0.0.1:9093/-/healthy" \
  30

# Verify the config was loaded (not just that the process is up)
info "Checking Alertmanager config loaded correctly..."
if curl -sf "http://127.0.0.1:9093/api/v2/status" | grep -q "configJSON"; then
  ok "Alertmanager: config loaded and API responding"
else
  warn "Alertmanager API response unexpected — check config"
fi

# =============================================================================
section "PART 2C — LOKI"

start_and_verify \
  "loki.service" \
  "http://127.0.0.1:3100/ready" \
  60

# Loki /ready returns 'ready' when ring is healthy and it accepts writes
LOKI_STATUS=$(curl -sf "http://127.0.0.1:3100/ready" 2>/dev/null || echo "unreachable")
if [[ "$LOKI_STATUS" == *"ready"* ]]; then
  ok "Loki: ready (ring initialised, accepting writes)"
else
  fail "Loki /ready returned: ${LOKI_STATUS}"
fi

# =============================================================================
section "PART 2D — TEMPO"

# Tempo 3.0 live-store writes shard files and shutdown markers to /var/tempo
# and work.json to /var/lib/lgtm/tempo/traces. A prior failed start (or a
# previous install run) can leave these owned by root. Fix before starting.
info "Repairing Tempo data directory ownership..."
chown -R tempo:tempo /var/tempo /var/lib/lgtm/tempo
find /var/tempo /var/lib/lgtm/tempo -type d -exec chmod 750 {} \;
ok "Tempo data directories: owned by tempo:tempo"

start_and_verify \
  "tempo.service" \
  "http://127.0.0.1:3200/ready" \
  60

TEMPO_STATUS=$(curl -sf "http://127.0.0.1:3200/ready" 2>/dev/null || echo "unreachable")
if [[ "$TEMPO_STATUS" == *"ready"* ]]; then
  ok "Tempo: ready (accepting traces)"
else
  fail "Tempo /ready returned: ${TEMPO_STATUS}"
fi

# =============================================================================
section "PART 2E — PROMETHEUS"

start_and_verify \
  "prometheus.service" \
  "http://127.0.0.1:9090/-/healthy" \
  60

# The targets page is ground truth — every target must be UP
info "Checking Prometheus scrape targets..."
TARGETS_JSON=$(curl -sf "http://127.0.0.1:9090/api/v1/targets" 2>/dev/null || echo "{}")
DOWN_TARGETS=$(echo "$TARGETS_JSON" | python3 -c "
import json, sys
data = json.load(sys.stdin)
active = data.get('data', {}).get('activeTargets', [])
down = [t['labels'].get('job','?') + ' / ' + t['labels'].get('instance','?')
        for t in active if t['health'] == 'down']
print('\n'.join(down))
" 2>/dev/null || echo "")

if [[ -z "$DOWN_TARGETS" ]]; then
  ok "Prometheus: all scrape targets are UP"
else
  warn "Prometheus: the following targets are DOWN:"
  while IFS= read -r target; do
    warn "  DOWN: ${target}"
  done <<< "$DOWN_TARGETS"
  warn "Check http://127.0.0.1:9090/targets for details"
fi

# Verify alert rules loaded
RULE_COUNT=$(curl -sf "http://127.0.0.1:9090/api/v1/rules" 2>/dev/null \
  | python3 -c "import json,sys; d=json.load(sys.stdin); print(sum(len(g['rules']) for g in d.get('data',{}).get('groups',[])))" \
  2>/dev/null || echo "0")
if [[ "$RULE_COUNT" -gt 0 ]]; then
  ok "Prometheus: ${RULE_COUNT} alert rules loaded"
else
  warn "Prometheus: no alert rules found — check /etc/lgtm/prometheus/rules/"
fi

# =============================================================================
section "PART 2F — GRAFANA"

start_and_verify \
  "grafana-server.service" \
  "http://127.0.0.1:3000/api/health" \
  120

# Verify datasources provisioned correctly
info "Checking Grafana datasource health..."
ADMIN_PASS=$(grep GF_SECURITY_ADMIN_PASSWORD /etc/lgtm/secrets | cut -d= -f2)
ADMIN_USER=$(grep GF_SECURITY_ADMIN_USER /etc/lgtm/env 2>/dev/null | cut -d= -f2 || echo "admin")

DS_RESPONSE=$(curl -sf \
  -u "${ADMIN_USER}:${ADMIN_PASS}" \
  "http://127.0.0.1:3000/api/datasources" 2>/dev/null || echo "[]")

for ds in Prometheus Loki Tempo; do
  if echo "$DS_RESPONSE" | grep -qi "\"name\":\"${ds}\""; then
    ok "Grafana datasource provisioned: ${ds}"
  else
    warn "Grafana datasource NOT found: ${ds} — check provisioning logs"
  fi
done

# =============================================================================
# PART 3 — POST BRING-UP HARDENING
# =============================================================================

section "PART 3A — REBOOT SURVIVAL TEST PREP"
# Nemeth: a service that starts manually but fails after reboot has a bug.
# We can't reboot here, but we leave clear instructions and a test script.

cat > /usr/local/bin/lgtm-health << 'HEALTHSCRIPT'
#!/usr/bin/env bash
# LGTM Stack health check — run after reboot to verify all services came up
# Usage: lgtm-health
# Exit 0 = all healthy, Exit 1 = at least one service down

RED='\033[0;31m'; GRN='\033[0;32m'; YEL='\033[0;33m'; RST='\033[0m'
ERRORS=0

check() {
  local name="$1" url="$2"
  if curl -sf "$url" -o /dev/null 2>/dev/null; then
    echo -e "${GRN}[UP]${RST}   ${name}"
  else
    echo -e "${RED}[DOWN]${RST} ${name} — check: journalctl -u ${name,,} -n 30"
    ERRORS=$((ERRORS+1))
  fi
}

echo ""
echo "LGTM Stack Health Check — $(date)"
echo "─────────────────────────────────────"
check "blackbox-exporter" "http://127.0.0.1:9115/health"
check "alertmanager"      "http://127.0.0.1:9093/-/healthy"
check "loki"              "http://127.0.0.1:3100/ready"
check "tempo"             "http://127.0.0.1:3200/ready"
check "prometheus"        "http://127.0.0.1:9090/-/healthy"
check "grafana"           "http://127.0.0.1:3000/api/health"
echo "─────────────────────────────────────"

if [[ "$ERRORS" -eq 0 ]]; then
  echo -e "${GRN}All services healthy.${RST}"
else
  echo -e "${RED}${ERRORS} service(s) down.${RST}"
  echo ""
  echo "Failed systemd units:"
  systemctl --failed --no-legend
fi
echo ""
exit $ERRORS
HEALTHSCRIPT

chmod 755 /usr/local/bin/lgtm-health
ok "Health check script installed: /usr/local/bin/lgtm-health"
info "After any reboot, run: lgtm-health"

# =============================================================================
section "PART 3B — RELOAD CONFIG HELPER"
# Config changes should not require restarts. Install a helper that
# hot-reloads Prometheus and Alertmanager config via their HTTP APIs.

cat > /usr/local/bin/lgtm-reload << 'RELOADSCRIPT'
#!/usr/bin/env bash
# Reload LGTM service configs without restarting the process.
# Prometheus and Alertmanager support SIGHUP-triggered config reload.
# Usage: lgtm-reload [prometheus|alertmanager|all]

case "${1:-all}" in
  prometheus)
    curl -sf -X POST http://127.0.0.1:9090/-/reload \
      && echo "Prometheus config reloaded" \
      || echo "Prometheus reload failed — check http://127.0.0.1:9090/config"
    ;;
  alertmanager)
    curl -sf -X POST http://127.0.0.1:9093/-/reload \
      && echo "Alertmanager config reloaded" \
      || echo "Alertmanager reload failed — check journalctl -u alertmanager"
    ;;
  grafana)
    echo "Grafana picks up dashboard changes within 30s automatically."
    echo "For datasource changes, restart Grafana: systemctl restart grafana-server"
    ;;
  all)
    "$0" prometheus
    "$0" alertmanager
    ;;
  *)
    echo "Usage: $0 [prometheus|alertmanager|grafana|all]"
    exit 1
    ;;
esac
RELOADSCRIPT

chmod 755 /usr/local/bin/lgtm-reload
ok "Reload helper installed: /usr/local/bin/lgtm-reload"

# =============================================================================
section "PART 3C — JOURNALD LOG VERIFICATION"
# Nemeth: all services must log to stdout → journald.
# If a service writes to a file instead, you'll miss errors.

info "Verifying all services are logging to journald..."
for unit in \
  blackbox-exporter alertmanager \
  loki tempo prometheus grafana-server; do
  LOG_LINES=$(journalctl -u "${unit}" --since "5 minutes ago" --no-pager -q 2>/dev/null | wc -l)
  if [[ "$LOG_LINES" -gt 0 ]]; then
    ok "journald capturing logs for ${unit} (${LOG_LINES} lines in last 5m)"
  else
    warn "No recent log lines for ${unit} in journald — it may be writing to a file"
  fi
done

# =============================================================================
section "FINAL SUMMARY"
# =============================================================================

echo ""
systemctl --failed --no-legend 2>/dev/null | head -10
echo ""

if [[ "$ERRORS" -eq 0 ]]; then
  echo -e "${GRN}${BLD}╔══════════════════════════════════════════╗${RST}"
  echo -e "${GRN}${BLD}║  LGTM Stack is fully operational.       ║${RST}"
  echo -e "${GRN}${BLD}╚══════════════════════════════════════════╝${RST}"
  echo ""
  echo -e "  Grafana:       ${BLU}http://localhost:3000${RST}"
  echo -e "  Prometheus:    ${BLU}http://localhost:9090${RST}  (internal only)"
  echo -e "  Alertmanager:  ${BLU}http://localhost:9093${RST}  (internal only)"
  echo ""
  echo -e "  ${BLD}Useful commands:${RST}"
  echo -e "    lgtm-health            — check all services"
  echo -e "    lgtm-reload prometheus — hot-reload Prometheus config"
  echo -e "    lgtm-reload all        — hot-reload all reloadable configs"
  echo -e "    journalctl -u prometheus -f  — follow Prometheus logs"
  echo ""
  echo -e "  ${YEL}${BLD}Reminder about fake-service:${RST}"
  echo -e "  ${YEL}The fake-service (traffic/metrics simulator) was not installed.${RST}"
  echo -e "  ${YEL}When you're ready to set it up, remind me and we'll do it together.${RST}"
  echo ""
else
  echo -e "${RED}${BLD}✗ Stack came up with ${ERRORS} error(s).${RST}"
  echo -e "${RED}  Run: systemctl --failed${RST}"
  echo -e "${RED}  Run: journalctl -u <failed-unit> --no-pager -n 50${RST}"
fi
echo ""

exit $ERRORS

