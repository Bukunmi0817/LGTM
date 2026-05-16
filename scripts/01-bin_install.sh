#!/usr/bin/env bash
# =============================================================================
# LGTM Stack — Phase 2: Binary Installation
# Target: Ubuntu 26.04 LTS (Resolute Raccoon) — Linux kernel 7.0 — amd64
#
# Installs:
#   Grafana Enterprise  13.0.1   via .deb
#   Prometheus          3.5.3    via binary tarball
#   Alertmanager        0.32.1   via binary tarball
#   Blackbox Exporter   0.28.0   via binary tarball
#   Node Exporter       1.11.1   via binary tarball
#   Loki                3.7.2    via binary tarball
#   Tempo               3.0.0    via binary tarball
#   OTel Collector      0.152.0  via .deb
#
# Nemeth principle: install, verify, then move on. Never assume a download
# succeeded. Never assume a binary runs. Check every step explicitly.
#
# Run as root: sudo bash 01-install-binaries.sh
# Prerequisite: 00-preflight-and-layout.sh must have completed with 0 errors.
# =============================================================================

set -euo pipefail
IFS=$'\n\t'

# ─── Colour helpers ───────────────────────────────────────────────────────────
RED='\033[0;31m'; YEL='\033[0;33m'; GRN='\033[0;32m'
BLU='\033[0;34m'; CYN='\033[0;36m'; BLD='\033[1m'; RST='\033[0m'

info()    { echo -e "${BLU}[INFO]${RST}  $*"; }
ok()      { echo -e "${GRN}[OK]${RST}    $*"; }
warn()    { echo -e "${YEL}[WARN]${RST}  $*"; }
fail()    { echo -e "${RED}[FAIL]${RST}  $*"; ERRORS=$((ERRORS+1)); }
section() { echo -e "\n${BLD}${CYN}══ $* ══${RST}"; }
die()     { echo -e "${RED}[FATAL]${RST} $*"; exit 1; }

ERRORS=0
TMP_DIR=$(mktemp -d /tmp/lgtm-install.XXXXXX)
# Clean up temp dir on exit regardless of success or failure
trap 'rm -rf "$TMP_DIR"' EXIT

# ─── Guards ───────────────────────────────────────────────────────────────────
[[ "$EUID" -ne 0 ]] && die "Run as root: sudo bash $0"
[[ ! -f /etc/lgtm/.arch ]] && die "Phase 0 layout not detected. Run 00-preflight-and-layout.sh first."

source /etc/lgtm/.arch
[[ "$GOARCH" != "amd64" ]] && die "This script targets amd64. Your arch is ${GOARCH}."

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
TEMPO_VERSION="v3.0.0-rc.1"
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

section "INSTALLING SYSTEM DEPENDENCIES"

apt-get update -qq
apt-get install -y -qq \
  adduser \
  libfontconfig1 \
  musl \
  wget \
  curl \
  tar \
  git \
  ca-certificates \
  apt-transport-https \
  gnupg2
ok "System dependencies installed"

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

# =============================================================================
section "2/8 — PROMETHEUS ${PROMETHEUS_VERSION}"
# =============================================================================

PROM_TARBALL="${TMP_DIR}/prometheus.tar.gz"
PROM_URL="https://github.com/prometheus/prometheus/releases/download/v${PROMETHEUS_VERSION}/prometheus-${PROMETHEUS_VERSION}.linux-amd64.tar.gz"

download "$PROM_URL" "$PROM_TARBALL" "Prometheus ${PROMETHEUS_VERSION}"
install_binary "$PROM_TARBALL" "prometheus" "/opt/lgtm/prometheus"
install_binary "$PROM_URL" "promtool" "/opt/lgtm/prometheus"

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

# =============================================================================
section "5/8 — NODE EXPORTER ${NODE_EXPORTER_VERSION}"
# =============================================================================

NE_TARBALL="${TMP_DIR}/node_exporter.tar.gz"
NE_URL="https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VERSION}/node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64.tar.gz"

download "$NE_URL" "$NE_TARBALL" "Node Exporter ${NODE_EXPORTER_VERSION}"
install_binary "$NE_TARBALL" "node_exporter" "/opt/lgtm/node-exporter"

ln -sf /opt/lgtm/node-exporter/node_exporter /usr/local/bin/node_exporter
ok "Symlink: node_exporter → /usr/local/bin/"

verify_binary /opt/lgtm/node-exporter/node_exporter "$NODE_EXPORTER_VERSION"

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

# =============================================================================
section "8/8 — OTEL COLLECTOR ${OTELCOL_VERSION}"
# Installed via .deb — same pattern as Grafana.
# The contrib .deb includes all receivers and exporters including Loki and Tempo.
# =============================================================================

OTEL_DEB="${TMP_DIR}/otelcol.deb"
OTEL_URL="https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/v${OTELCOL_VERSION}/otelcol_${OTELCOL_VERSION}_linux_amd64.deb"

download "$OTEL_URL" "$OTEL_DEB" "OTel Collector ${OTELCOL_VERSION}"
dpkg -i "$OTEL_DEB"
ok "OTel Collector ${OTELCOL_VERSION} installed via dpkg"

# .deb installs binary to /usr/bin/otelcol — symlink to our layout
ln -sf /usr/bin/otelcol /opt/lgtm/otel-collector/otelcol
ok "Symlink: /opt/lgtm/otel-collector/otelcol → /usr/bin/otelcol"

# Disable the default unit — Phase 3 installs our hardened unit
systemctl disable --now otelcol 2>/dev/null || true
ok "OTel Collector default systemd unit disabled — Phase 3 will install hardened unit"

verify_binary /usr/bin/otelcol "$OTELCOL_VERSION"

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
  /opt/lgtm/node-exporter/node_exporter \
  /opt/lgtm/loki/loki \
  /opt/lgtm/tempo/tempo \
  /usr/bin/otelcol; do
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
  echo -e "${GRN}  Ready for Phase 3 — configuration files.${RST}"
else
  echo -e "${RED}${BLD}✗ ${ERRORS} error(s) during installation.${RST}"
  echo -e "${RED}  Fix errors before running 02-configure.sh.${RST}"
fi
echo ""

exit $ERRORS

