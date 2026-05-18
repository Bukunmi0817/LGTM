#!/usr/bin/env bash
# =============================================================================
# Pushgateway installer — runs as part of LGTM monitoring server bootstrap.
# Prometheus Pushgateway receives DORA metrics pushed from GitHub Actions
# and exposes them on :9091 for Prometheus to scrape.
#
# Follows the Nemeth principle: install, verify, then move on.
# =============================================================================
set -euo pipefail

RED='\033[0;31m'; GRN='\033[0;32m'; YEL='\033[0;33m'; BLD='\033[1m'; RST='\033[0m'
ok()   { echo -e "${GRN}[OK]${RST}    $*"; }
info() { echo -e "[INFO]  $*"; }
fail() { echo -e "${RED}[FAIL]${RST}  $*"; exit 1; }

[[ "$EUID" -ne 0 ]] && fail "Run as root: sudo bash $0"

PUSHGATEWAY_VERSION="1.9.0"
ARCH=$(uname -m)
[[ "$ARCH" == "aarch64" ]] && GOARCH="arm64" || GOARCH="amd64"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# ── Create data directory ─────────────────────────────────────────────────────
info "Creating Pushgateway data directory..."
mkdir -p /var/lib/pushgateway
# Prometheus user already exists from lgtm-stack.sh — reuse it
chown prometheus:prometheus /var/lib/pushgateway
chmod 750 /var/lib/pushgateway
ok "Directory: /var/lib/pushgateway (prometheus:prometheus, 750)"

# ── Download and install binary ───────────────────────────────────────────────
info "Downloading Pushgateway ${PUSHGATEWAY_VERSION}..."
URL="https://github.com/prometheus/pushgateway/releases/download/v${PUSHGATEWAY_VERSION}/pushgateway-${PUSHGATEWAY_VERSION}.linux-${GOARCH}.tar.gz"
wget -q --show-progress --tries=3 --timeout=60 -O "${TMP}/pushgateway.tar.gz" "$URL"
ok "Downloaded: pushgateway-${PUSHGATEWAY_VERSION}.linux-${GOARCH}.tar.gz"

tar -xzf "${TMP}/pushgateway.tar.gz" -C "$TMP" --strip-components=1
cp "${TMP}/pushgateway" /usr/local/bin/pushgateway
chown root:root /usr/local/bin/pushgateway
chmod 755       /usr/local/bin/pushgateway
ok "Binary installed: /usr/local/bin/pushgateway"

# Verify
ACTUAL_VER=$(/usr/local/bin/pushgateway --version 2>&1 | head -1)
if echo "$ACTUAL_VER" | grep -q "$PUSHGATEWAY_VERSION"; then
  ok "Version confirmed: $ACTUAL_VER"
else
  info "Version string: $ACTUAL_VER (may still be valid)"
fi

# ── Write systemd unit ────────────────────────────────────────────────────────
info "Writing systemd unit file..."
cat > /etc/systemd/system/pushgateway.service << 'UNIT'
[Unit]
Description=Prometheus Pushgateway
Documentation=https://github.com/prometheus/pushgateway
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=prometheus
Group=prometheus
ExecStart=/usr/local/bin/pushgateway \
  --web.listen-address=0.0.0.0:9091 \
  --persistence.file=/var/lib/pushgateway/metrics.db \
  --persistence.interval=5m \
  --log.level=info
Restart=on-failure
RestartSec=5s
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
ReadWritePaths=/var/lib/pushgateway

[Install]
WantedBy=multi-user.target
UNIT

chown root:root /etc/systemd/system/pushgateway.service
chmod 644       /etc/systemd/system/pushgateway.service
ok "Unit written: /etc/systemd/system/pushgateway.service"

# Note: listen on 0.0.0.0 not 127.0.0.1 because GitHub Actions will push
# from outside the server. Port 9091 is controlled by the security group.

# ── Enable and start ──────────────────────────────────────────────────────────
systemctl daemon-reload
systemctl enable pushgateway
systemctl start pushgateway
ok "Pushgateway enabled and started"

# ── Health check ──────────────────────────────────────────────────────────────
info "Waiting for Pushgateway to be healthy..."
for i in {1..15}; do
  if curl -sf http://localhost:9091/metrics -o /dev/null; then
    ok "Pushgateway healthy at :9091 (took $((i*2))s)"
    break
  fi
  sleep 2
  [[ "$i" -eq 15 ]] && fail "Pushgateway did not become healthy after 30s — check: journalctl -u pushgateway -n 30"
done

# ── Add to Prometheus scrape config ──────────────────────────────────────────
PROM_CONF=/etc/lgtm/prometheus/prometheus.yml
if grep -q '"pushgateway"' "$PROM_CONF" 2>/dev/null; then
  ok "Prometheus scrape config: pushgateway job already present"
else
  info "Adding pushgateway scrape job to $PROM_CONF..."
  cat >> "$PROM_CONF" << 'SCRAPE'

  # ── Pushgateway — receives DORA metrics pushed from GitHub Actions ───────
  - job_name: "pushgateway"
    honor_labels: true
    scrape_interval: 15s
    static_configs:
      - targets: ["127.0.0.1:9091"]
        labels:
          environment: "production"
SCRAPE
  ok "Pushgateway scrape job added to prometheus.yml"

  # Reload Prometheus config (it must already be running)
  if curl -sf -X POST http://127.0.0.1:9090/-/reload; then
    ok "Prometheus config reloaded — pushgateway target active"
  else
    info "Could not reload Prometheus yet — it will pick up the config on next start"
  fi
fi

# ── Add to lgtm-health script ─────────────────────────────────────────────────
HEALTH_SCRIPT=/usr/local/bin/lgtm-health
if [[ -f "$HEALTH_SCRIPT" ]] && ! grep -q "pushgateway" "$HEALTH_SCRIPT"; then
  info "Adding pushgateway to lgtm-health check script..."
  sed -i '/check "grafana"/a check "pushgateway"     "http://127.0.0.1:9091/metrics"' "$HEALTH_SCRIPT"
  ok "pushgateway added to lgtm-health"
fi

echo ""
echo -e "${GRN}${BLD}✓ Pushgateway ${PUSHGATEWAY_VERSION} installed and running on :9091${RST}"
echo ""
echo "  Test with:"
echo "    curl http://localhost:9091/metrics | head -5"
echo ""
echo "  Push a test metric:"
echo "    echo 'test_metric 1' | curl -s --data-binary @- http://localhost:9091/metrics/job/test"
echo ""
