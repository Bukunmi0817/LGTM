#!/usr/bin/env bash
# =============================================================================
# LGTM Stack — Phase 5: Hardening, Bring-Up & Verification
# Target: Ubuntu 26.04 LTS — systemd 255+
#
# This script does three things in strict order:
#
#   1. HARDEN  — firewall rules, file permission audit, sysctl final check
#   2. START   — services in dependency order, one at a time
#   3. VERIFY  — each service must pass its health check before the next starts
#
# Nemeth principle: never start a service and assume it worked. Test it.
# If step N fails, the script stops. You fix it. Then re-run.
# Do not proceed to step N+1 with a broken N — you will spend hours
# debugging cascading failures that all trace back to one root cause.
#
# Run as root: sudo bash 04-harden.sh
# Prerequisite: 03-systemd-units.sh must have completed with 0 errors.
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

[[ "$EUID" -ne 0 ]] && die "Run as root: sudo bash $0"
[[ ! -f /etc/systemd/system/prometheus.service ]] && die "Phase 4 not detected. Run 03-systemd.sh first."

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

  # Enable without interactive prompt
  ufw --force enable
  ok "ufw enabled: SSH and Grafana(:3000) open, all else denied"

  ufw status verbose
else
  warn "ufw not installed — install with: apt-get install ufw"
  warn "Manually restrict access to ports 9090 9093 9100 9115 3100 3200 4317 4318 8888"
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
audit_perm /opt/lgtm/node-exporter/node_exporter      755 root:root
audit_perm /opt/lgtm/blackbox-exporter/blackbox_exporter 755 root:root
audit_perm /usr/bin/otelcol-contrib                   755 root:root

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
if grep -q "SLACK_WEBHOOK_URL=https://hooks.slack.com/services/$" /etc/lgtm/secrets; then
  die "SLACK_WEBHOOK_URL is still a placeholder in /etc/lgtm/secrets. Set it before starting services."
fi
if grep -q "change_me_in_production" /etc/lgtm/secrets; then
  warn "GF_SECURITY_ADMIN_PASSWORD is still the default — change it after first login"
fi
ok "Secrets look populated"

# =============================================================================
# PART 2 — SERVICE BRING-UP IN DEPENDENCY ORDER
# Each service is started, waited on, and health-checked before the next.
# If any service fails its health check, the script stops.
# =============================================================================

section "PART 2A — NODE EXPORTER"

start_and_verify \
  "node-exporter.service" \
  "http://127.0.0.1:9100/metrics" \
  30

# Spot-check that CPU metrics are present
if curl -sf "http://127.0.0.1:9100/metrics" | grep -q "node_cpu_seconds_total"; then
  ok "node_cpu_seconds_total: present in metrics output"
else
  fail "node_cpu_seconds_total not found — node-exporter may not have /proc access"
fi

# =============================================================================
section "PART 2B — BLACKBOX EXPORTER"

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
section "PART 2C — ALERTMANAGER"

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
section "PART 2D — LOKI"

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
section "PART 2E — TEMPO"

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
section "PART 2F — OTEL COLLECTOR"

start_and_verify \
  "otelcol.service" \
  "http://127.0.0.1:8888/metrics" \
  30

# Verify the pipelines are up — otelcol exposes its own metrics
if curl -sf "http://127.0.0.1:8888/metrics" | grep -q "otelcol_process_uptime"; then
  ok "OTel Collector: pipelines running (metrics endpoint healthy)"
else
  warn "Could not confirm OTel Collector pipeline status"
fi

# =============================================================================
section "PART 2G — PROMETHEUS"

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
section "PART 2H — GRAFANA"

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
check "node-exporter"     "http://127.0.0.1:9100/metrics"
check "blackbox-exporter" "http://127.0.0.1:9115/health"
check "alertmanager"      "http://127.0.0.1:9093/-/healthy"
check "loki"              "http://127.0.0.1:3100/ready"
check "tempo"             "http://127.0.0.1:3200/ready"
check "otelcol"           "http://127.0.0.1:8888/metrics"
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
  node-exporter blackbox-exporter alertmanager \
  loki tempo otelcol prometheus grafana-server; do
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

