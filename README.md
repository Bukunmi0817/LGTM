# LGTM Observability Platform

Production-grade observability and reliability platform built with the LGTM stack (Loki, Grafana, Tempo, Prometheus). Fully provisioned with Terraform. No manual configuration required.

---

## One-command deployment

```bash
git clone https://github.com/YOUR_ORG/YOUR_REPO.git
cd observability-platform/terraform
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your values (AWS keys, DuckDNS token, Slack webhook)
terraform init
terraform apply
```

That single `terraform apply` command will:
1. Provision an EC2 instance (t3.large, Ubuntu 22.04, 30GB EBS) in your chosen AWS region
2. Create a VPC, public subnet, internet gateway, and security group with all required ports
3. Allocate an Elastic IP so the server IP never changes on restart
4. Call the DuckDNS API to point your subdomain at the server's IP
5. SSH into the server, upload all configs, and install Docker
6. Issue a Let's Encrypt SSL certificate via the DuckDNS DNS challenge
7. Launch all 9 services via Docker Compose with `restart: always` policies
8. Print all service URLs as Terraform outputs

**Prerequisites:**
- AWS account with programmatic access configured (`aws configure`)
- An SSH key pair (`ssh-keygen -t rsa -b 4096`)
- A DuckDNS account with a subdomain created at https://duckdns.org
- A Slack workspace with an Incoming Webhook configured for `#devops-alerts`

---

## Architecture

```
Data Sources → Collectors → Storage → Grafana Dashboards
                              ↓
                         Alertmanager → Slack #DevOps-Alerts
```

| Service | Port | Purpose |
|---------|------|---------|
| Grafana | 3000 | Unified observability UI |
| Prometheus | 9090 | Metrics storage + alert rule engine |
| Loki | 3100 | Log aggregation |
| Tempo | 3200 | Distributed tracing |
| Alertmanager | 9093 | Alert routing |
| Node Exporter | 9100 | Host metrics (CPU, RAM, disk, network) |
| Blackbox Exporter | 9115 | Uptime + SSL probing |
| OTel Collector | 4317/4318 | Trace + log ingestion |
| Sample App | 8000 | Instrumented service |

**Retention:** Metrics: 15 days | Logs: 15 days (360h) | Traces: 15 days

---

## Dashboard guide

Access Grafana at `http://YOUR_SUBDOMAIN.duckdns.org:3000` — default login is `admin` / your chosen password.

| Dashboard | UID | What it shows |
|-----------|-----|--------------|
| DORA Metrics | `dora` | Deployment Frequency, Lead Time, CFR, MTTR with DORA benchmark classification |
| SLO & Error Budget | `slo-error-budget` | SLI vs SLO gauges, error budget remaining, burn rate, 7d and 30d compliance |
| Node Exporter | `node-exporter` | CPU (total + per-core), memory, disk I/O, network I/O, load averages |
| Blackbox Exporter | `blackbox` | Uptime timeline, HTTP response p50/p90/p99, SSL expiry countdown |
| Unified Observability | `unified` | Metric spike → correlated Loki logs → clickable trace ID → Tempo |

### Unified dashboard drill-down (non-negotiable acceptance criterion)

1. Open the Unified Observability dashboard
2. Find a spike in the error rate or latency panel
3. Click the time range on the panel → "View in Explore"
4. Switch to the Loki datasource — logs from the same time window are already filtered
5. In a log line, find the `traceID` field — it is a clickable link
6. Click the trace ID → Tempo opens showing the full request trace
7. Identify the slow or failing span — this is the exact service and line responsible

---

## Error Budget Policy

### Definitions

- **SLO window:** Rolling 30 days
- **Availability SLO:** 99.5% of Blackbox HTTP probes return 2xx
- **Latency SLO:** 95% of requests complete under 500ms
- **Error Rate SLO:** 99% of requests are non-5xx

### Error budget calculations

| SLO | Target | Error Budget (30 days) |
|-----|--------|----------------------|
| Availability | 99.5% | 0.5% × 43,200 min = **216 minutes** |
| Latency | 95% p95 < 500ms | 5% of requests may exceed threshold |
| Error Rate | 99% | 1% × 43,200 min = **432 minutes** |

### Burn rate thresholds

| Condition | Burn Rate | Alert | Action |
|-----------|-----------|-------|--------|
| 2% budget in 1 hour | 14.4× | CRITICAL — SLOFastBurn | Page on-call immediately |
| 5% budget in 6 hours | 5× | WARNING — SLOSlowBurn | Investigate before next sprint |

### Policy responses

**At 50% error budget consumed:**
- Engineering lead is notified
- No new feature deployments until root cause is identified
- Reliability review scheduled within 24 hours

**At 100% error budget consumed (budget exhausted):**
- Feature freeze — all engineering work shifts to reliability
- Incident declared if not already active
- Post-incident review mandatory within 48 hours
- SLO reviewed and potentially revised at next monthly review

**Ownership:** The on-call engineer owns the error budget decision in the moment. The engineering lead owns the monthly review and policy revision.

**Review cadence:** SLOs are reviewed monthly. Targets are adjusted if the service consistently operates with >50% budget remaining (target too loose) or regularly exhausts the budget despite good engineering (target too tight).

---

## Runbooks

Every alert rule has a corresponding runbook in `/runbooks/`:

| Alert | Runbook |
|-------|---------|
| CPUWarning | [cpu_warning.md](runbooks/cpu_warning.md) |
| CPUCritical | [cpu_critical.md](runbooks/cpu_critical.md) |
| MemoryWarning | [memory_warning.md](runbooks/memory_warning.md) |
| MemoryCritical | [memory_critical.md](runbooks/memory_critical.md) |
| DiskWarning | [disk_warning.md](runbooks/disk_warning.md) |
| DiskCritical | [disk_critical.md](runbooks/disk_critical.md) |
| ServerDown | [server_downtime.md](runbooks/server_downtime.md) |
| SLOFastBurn | [slo_fast_burn.md](runbooks/slo_fast_burn.md) |
| SLOSlowBurn | [slo_slow_burn.md](runbooks/slo_slow_burn.md) |
| HighChangeFailureRate | [cfr_threshold.md](runbooks/cfr_threshold.md) |
| MTTRExceeded | [mttr_exceeded.md](runbooks/mttr_exceeded.md) |

---

## Alertmanager silencing

To silence an alert during planned maintenance:

```bash
# Via amtool CLI
amtool --alertmanager.url=http://localhost:9093 silence add \
  alertname="CPUWarning" \
  --duration=2h \
  --comment="Planned maintenance window"

# Or via the Alertmanager UI at http://YOUR_IP:9093/#/silences
```

Silences are scoped by label matchers. The most common patterns:

```
# Silence all alerts for a specific host
instance="monitoring-server"

# Silence all warnings during a deployment window
severity="warning"

# Silence a specific alert
alertname="SLOSlowBurn"
```
# trigger
