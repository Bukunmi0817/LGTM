#!/usr/bin/env bash
# =============================================================================
# LGTM Stack — Phase 4: systemd Unit Files
# Target: Ubuntu 26.04 LTS — systemd 255+
#
# Writes and enables systemd unit files for every LGTM service.
# Installation order follows dependency graph:
#
#   node-exporter      (no deps)   ─┐
#   blackbox-exporter  (no deps)   ─┤
#   alertmanager       (no deps)   ─┤─→ prometheus ─→ grafana
#   loki               (no deps)   ─┤
#   tempo              (no deps)   ─┤─→ otel-collector
#
# Nemeth principle: document the dependency graph explicitly. systemd's
# After= and Wants= make implicit boot-time ordering explicit and auditable.
# A service that starts before its dependencies is a service that silently
# fails on first boot and only works on second boot.
#
# Security hardening applied to every unit (Nemeth ch.27 — least privilege):
#   User=/Group=          run as dedicated non-root system user
#   NoNewPrivileges=yes   process cannot gain additional privileges via setuid
#   PrivateTmp=yes        service gets its own /tmp — prevents /tmp attacks
#   ProtectSystem=full    /usr /boot /etc read-only for the service process
#   ReadWritePaths=       explicit whitelist of dirs the service can write to
#   ProtectHome=yes       /home /root /run/user invisible to service
#   CapabilityBoundingSet= empty capability set for services that need none
#   LimitNOFILE=          per-service file descriptor limits (overrides ulimits)
#
# Run as root: sudo bash 03-systemd-units.sh
# Prerequisite: 02-configure.sh must have completed with 0 errors.
# =============================================================================

set -euo pipefail
IFS=$'\n\t'

RED='\033[0;31m'; YEL='\033[0;33m'; GRN='\033[0;32m'
BLU='\033[0;34m'; CYN='\033[0;36m'; BLD='\033[1m'; RST='\033[0m'

info()    { echo -e "${BLU}[INFO]${RST}  $*"; }
ok()      { echo -e "${GRN}[OK]${RST}    $*"; }
warn()    { echo -e "${YEL}[WARN]${RST}  $*"; }
fail()    { echo -e "${RED}[FAIL]${RST}  $*"; ERRORS=$((ERRORS+1)); }
section() { echo -e "\n${BLD}${CYN}══ $* ══${RST}"; }
die()     { echo -e "${RED}[FATAL]${RST} $*"; exit 1; }

ERRORS=0
SYSTEMD_DIR=/etc/systemd/system

[[ "$EUID" -ne 0 ]] && die "Run as root: sudo bash $0"
[[ ! -f /etc/lgtm/prometheus/prometheus.yml ]] && die "Phase 3 not detected. Run 02-configure.sh first."

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

# =============================================================================
section "1/8 — NODE EXPORTER"
# Simplest unit. No config file, no upstream dependencies.
# Needs access to /proc and /sys — hence ReadOnlyPaths and
# --path flags pointing to the host filesystem.
# =============================================================================

install_unit "node-exporter.service" << 'EOF'
[Unit]
Description=Prometheus Node Exporter
Documentation=https://github.com/prometheus/node_exporter
# No After= needed — node-exporter has no service dependencies.
# It is a leaf node in the dependency graph.
After=network.target

[Service]
Type=simple
User=exporter
Group=exporter
EnvironmentFile=-/etc/lgtm/env

ExecStart=/opt/lgtm/node-exporter/node_exporter \
  --path.procfs=/proc \
  --path.sysfs=/sys \
  --path.rootfs=/ \
  --collector.filesystem.mount-points-exclude=^/(sys|proc|dev|host|etc)($$|/) \
  --web.listen-address=127.0.0.1:9100

# Restart policy: restart on any non-zero exit.
# RestartSec=5: wait 5 seconds before restart to avoid thrashing.
Restart=on-failure
RestartSec=5s

# ── Security hardening ────────────────────────────────────────────────────
NoNewPrivileges=yes
PrivateTmp=yes
ProtectHome=yes
# node-exporter reads /proc and /sys — ProtectSystem=full allows this
# because those are not under /usr /boot /etc
ProtectSystem=full
ReadOnlyPaths=/proc /sys /
ReadWritePaths=

# File descriptor limit — node-exporter opens one fd per metric file in /proc
LimitNOFILE=8192

# ── Resource limits ───────────────────────────────────────────────────────
# Prevent a runaway node-exporter from consuming the host
MemoryMax=256M
CPUQuota=20%

[Install]
WantedBy=multi-user.target
EOF

# =============================================================================
section "2/8 — BLACKBOX EXPORTER"
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

# Alertmanager data dir (not created in Phase 0 — add now)
mkdir -p /var/lib/lgtm/alertmanager
chown alertmanager:alertmanager /var/lib/lgtm/alertmanager
chmod 750 /var/lib/lgtm/alertmanager
ok "Alertmanager data dir: /var/lib/lgtm/alertmanager"

# =============================================================================
section "4/8 — LOKI"
# =============================================================================

install_unit "loki.service" << 'EOF'
[Unit]
Description=Grafana Loki Log Aggregation
Documentation=https://grafana.com/docs/loki/latest/
After=network.target
# OTel Collector must start after Loki — declared in otel-collector.service.
# We don't declare it here to avoid circular dependencies.

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
section "5/8 — TEMPO"
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
ReadWritePaths=/var/lib/lgtm/tempo /var/log/lgtm/tempo
CapabilityBoundingSet=

LimitNOFILE=32768
MemoryMax=2G
CPUQuota=50%

[Install]
WantedBy=multi-user.target
EOF

# =============================================================================
section "6/8 — OTEL COLLECTOR"
# Must start after Loki and Tempo — it ships data to both.
# Wants= (not Requires=) — collector starts even if Loki/Tempo aren't up,
# but will log errors until they come up. Resilient by design.
# =============================================================================

install_unit "otelcol.service" << 'EOF'
[Unit]
Description=OpenTelemetry Collector
Documentation=https://opentelemetry.io/docs/collector/
After=network.target loki.service tempo.service
Wants=loki.service tempo.service

[Service]
Type=simple
User=exporter
Group=exporter
EnvironmentFile=-/etc/lgtm/env

ExecStart=/usr/bin/otelcol \
  --config=/etc/lgtm/otel-collector/otel-config.yml

Restart=on-failure
RestartSec=5s

# ── Security hardening ────────────────────────────────────────────────────
NoNewPrivileges=yes
PrivateTmp=yes
ProtectHome=yes
ProtectSystem=full
ReadWritePaths=/var/log/lgtm
CapabilityBoundingSet=

LimitNOFILE=16384
MemoryMax=512M
CPUQuota=30%

[Install]
WantedBy=multi-user.target
EOF

# =============================================================================
section "7/8 — PROMETHEUS"
# Starts after exporters and alertmanager.
# Uses Wants= for exporters (non-fatal if missing) but Requires= for
# alertmanager (prometheus with no alertmanager is broken by design).
# =============================================================================

install_unit "prometheus.service" << 'EOF'
[Unit]
Description=Prometheus Metrics Server
Documentation=https://prometheus.io/docs/
After=network.target node-exporter.service blackbox-exporter.service alertmanager.service
Wants=node-exporter.service blackbox-exporter.service
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
section "8/8 — GRAFANA"
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
  node-exporter.service
  blackbox-exporter.service
  alertmanager.service
  loki.service
  tempo.service
  otelcol.service
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
  echo -e "${GRN}  Ready for Phase 5 — hardening and bring-up.${RST}"
  echo ""
  echo -e "${BLD}Services are enabled but NOT started.${RST}"
  echo -e "Run ${YEL}04-harden.sh${RST} next — it starts services in dependency order"
  echo -e "and verifies each one before proceeding."
else
  echo -e "${RED}${BLD}✗ ${ERRORS} error(s). Fix before running 04-harden.sh.${RST}"
fi
echo ""

exit $ERRORS

