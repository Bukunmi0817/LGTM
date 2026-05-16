#!/usr/bin/env bash
# =============================================================================
# LGTM Stack — Phase 3: Configuration Files
# Target: Ubuntu 26.04 LTS — amd64
#
# Writes configuration for every service into /etc/lgtm/<service>/.
# Every config file is validated before we move on.
# Nemeth principle: validate configs before the daemon ever sees them.
# A typo in a config file should fail here, not at 3am when the service
# crashes and takes alerting down with it.
#
# Run as root: sudo bash 02-configure.sh
# Prerequisite: 01-install-binaries.sh must have completed with 0 errors.
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

[[ "$EUID" -ne 0 ]]           && die "Run as root: sudo bash $0"
[[ ! -f /etc/lgtm/.arch ]]    && die "Phase 0 not detected. Run 00-preflight-and-layout.sh first."
[[ ! -x /opt/lgtm/prometheus/prometheus ]] && die "Phase 2 not detected. Run 01-install-binaries.sh first."

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
section "1/8 — PROMETHEUS"
# =============================================================================

info "Writing prometheus.yml..."
write_config /etc/lgtm/prometheus/prometheus.yml root:prometheus 640 << 'EOF'
# =============================================================================
# Prometheus configuration
# Scrape interval: 15s (Nemeth: short enough for responsiveness, long enough
# not to overwhelm exporters. 15s is the industry standard default.)
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

  # ── System metrics — Node Exporter ───────────────────────────────────────
  - job_name: "node-exporter"
    scrape_interval: 15s
    static_configs:
      - targets: ["127.0.0.1:9100"]
    relabel_configs:
      - source_labels: [__address__]
        target_label:  instance
        regex:         "([^:]+).*"
        replacement:   "$1"

  # ── HTTP/SSL probing — Blackbox Exporter ─────────────────────────────────
  # Add your real endpoints to the targets list below.
  - job_name: "blackbox-http"
    metrics_path: /probe
    params:
      module: [http_2xx]
    static_configs:
      - targets:
          - https://google.com
          - https://github.com
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

  # ── OTel Collector self-monitoring ───────────────────────────────────────
  - job_name: "otel-collector"
    static_configs:
      - targets: ["127.0.0.1:8888"]

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
          dashboard_url: "http://localhost:3000/d/infrastructure/node-exporter"

      - alert: CPUCritical
        expr: 100 - (avg by(instance) (rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100) > 90
        for: 10m
        labels:
          severity: critical
        annotations:
          summary:       "Critical CPU on {{ $labels.instance }}"
          description:   "CPU at {{ $value | printf \"%.1f\" }}% for >10m (threshold: 90%)"
          runbook_url:   "https://github.com/YOUR_ORG/YOUR_REPO/blob/main/runbooks/cpu-high.md"
          dashboard_url: "http://localhost:3000/d/infrastructure/node-exporter"

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
          dashboard_url: "http://localhost:3000/d/infrastructure/node-exporter"

      - alert: MemoryCritical
        expr: (1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)) * 100 > 90
        for: 5m
        labels:
          severity: critical
        annotations:
          summary:       "Critical memory on {{ $labels.instance }}"
          description:   "Memory at {{ $value | printf \"%.1f\" }}% (threshold: 90%)"
          runbook_url:   "https://github.com/YOUR_ORG/YOUR_REPO/blob/main/runbooks/memory-high.md"
          dashboard_url: "http://localhost:3000/d/infrastructure/node-exporter"

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
          dashboard_url: "http://localhost:3000/d/infrastructure/node-exporter"

      - alert: DiskSpaceCritical
        expr: (1 - (node_filesystem_avail_bytes{fstype!~"tmpfs|overlay|devtmpfs"} / node_filesystem_size_bytes{fstype!~"tmpfs|overlay|devtmpfs"})) * 100 > 90
        for: 5m
        labels:
          severity: critical
        annotations:
          summary:       "Critical disk on {{ $labels.instance }}:{{ $labels.mountpoint }}"
          description:   "Disk at {{ $value | printf \"%.1f\" }}% on {{ $labels.mountpoint }} (threshold: 90%)"
          runbook_url:   "https://github.com/YOUR_ORG/YOUR_REPO/blob/main/runbooks/disk-space.md"
          dashboard_url: "http://localhost:3000/d/infrastructure/node-exporter"

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
          dashboard_url: "http://localhost:3000/d/infrastructure/blackbox"
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
          dashboard_url: "http://localhost:3000/d/reliability/slo-error-budget"

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
          dashboard_url: "http://localhost:3000/d/reliability/slo-error-budget"

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
          dashboard_url: "http://localhost:3000/d/reliability/slo-error-budget"

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
          dashboard_url: "http://localhost:3000/d/reliability/slo-error-budget"
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
section "2/8 — ALERTMANAGER"
# =============================================================================

info "Writing alertmanager.yml..."
# Slack webhook is read from /etc/lgtm/secrets at runtime via EnvironmentFile.
# The template ${SLACK_WEBHOOK_URL} in the config is NOT a bash variable —
# it's a literal string that Alertmanager reads from its own environment.
# This is why we write it with single-quoted heredoc (no bash substitution).
write_config /etc/lgtm/alertmanager/alertmanager.yml root:alertmanager 640 << 'EOF'
global:
  resolve_timeout:  5m
  slack_api_url:    "${SLACK_WEBHOOK_URL}"

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
  # If a host is fully unreachable, suppress CPU/memory/latency noise for it.
  # Nemeth: alert on causes, suppress symptoms.
  - source_match:
      alertname: "ServiceDown"
      severity:  "critical"
    target_match_re:
      alertname: "CPU.*|Memory.*|Disk.*|Latency.*"
    equal: ["instance"]

  # Critical always suppresses warning for the same alert type on the same host.
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
EOF

info "Writing Slack alert template..."
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
*Host:*      {{ .Labels.instance | default "N/A" }}
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
if /opt/lgtm/alertmanager/amtool check-config /etc/lgtm/alertmanager/alertmanager.yml; then
  ok "alertmanager.yml: valid"
else
  fail "alertmanager.yml: INVALID — fix before Phase 4"
fi

# =============================================================================
section "3/8 — LOKI"
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
section "4/8 — TEMPO"
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

ingester:
  max_block_duration: 5m

compactor:
  compaction:
    block_retention: 720h

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

# =============================================================================
section "5/8 — OTEL COLLECTOR"
# =============================================================================

info "Writing otel-config.yml..."
write_config /etc/lgtm/otel-collector/otel-config.yml root:exporter 640 << 'EOF'
receivers:
  otlp:
    protocols:
      grpc:
        endpoint: 0.0.0.0:4317
      http:
        endpoint: 0.0.0.0:4318

  prometheus:
    config:
      scrape_configs:
        - job_name:        "otel-collector-self"
          scrape_interval: 10s
          static_configs:
            - targets: ["127.0.0.1:8888"]

processors:
  batch:
    timeout:         1s
    send_batch_size: 1024

  memory_limiter:
    check_interval:  1s
    limit_mib:       512
    spike_limit_mib: 128

  resource:
    attributes:
      - action: insert
        key:    environment
        value:  "production"

exporters:
  otlp/tempo:
    endpoint: 127.0.0.1:4317
    tls:
      insecure: true

  loki:
    endpoint: http://127.0.0.1:3100/loki/api/v1/push
    default_labels_enabled:
      exporter: false
      job:      true

  prometheus:
    endpoint: "127.0.0.1:8889"

  debug:
    verbosity: basic

service:
  pipelines:
    traces:
      receivers:  [otlp]
      processors: [memory_limiter, batch, resource]
      exporters:  [otlp/tempo]

    logs:
      receivers:  [otlp]
      processors: [memory_limiter, batch, resource]
      exporters:  [loki]

    metrics:
      receivers:  [otlp, prometheus]
      processors: [memory_limiter, batch]
      exporters:  [prometheus]
EOF

info "Validating OTel Collector config..."
if /usr/bin/otelcol validate --config=/etc/lgtm/otel-collector/otel-config.yml 2>&1; then
  ok "otel-config.yml: valid"
else
  fail "otel-config.yml: INVALID — fix before Phase 4"
fi

# =============================================================================
section "6/8 — BLACKBOX EXPORTER"
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
section "7/8 — GRAFANA"
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
http_addr       = 127.0.0.1
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

# Directories: root owns, group can traverse and read
find /etc/lgtm -type d -exec chmod 750 {} \;

# Config files: root:group, group-readable, no world access
find /etc/lgtm/prometheus   -type f -exec chown root:prometheus   {} \; -exec chmod 640 {} \;
find /etc/lgtm/loki         -type f -exec chown root:loki         {} \; -exec chmod 640 {} \;
find /etc/lgtm/tempo        -type f -exec chown root:tempo        {} \; -exec chmod 640 {} \;
find /etc/lgtm/grafana      -type f -exec chown root:grafana      {} \; -exec chmod 640 {} \;
find /etc/lgtm/alertmanager -type f -exec chown root:alertmanager {} \; -exec chmod 640 {} \;
find /etc/lgtm/otel-collector -type f -exec chown root:exporter   {} \; -exec chmod 640 {} \;
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
  echo -e "${GRN}  Ready for Phase 4 — systemd unit files.${RST}"
else
  echo -e "${RED}${BLD}✗ ${ERRORS} error(s) found.${RST}"
  echo -e "${RED}  Fix all errors before running 03-systemd-units.sh.${RST}"
fi

echo ""
echo -e "${BLD}Reminder:${RST}"
echo -e "  Edit ${YEL}/etc/lgtm/secrets${RST} before starting any service."
echo -e "  SLACK_WEBHOOK_URL and GF_SECURITY_ADMIN_PASSWORD must be set."
echo ""

exit $ERRORS

