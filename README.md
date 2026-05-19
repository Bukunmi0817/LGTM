# LGTM Observability Stack

A production-grade observability platform deployed on AWS using Terraform. Runs the full LGTM stack — Loki, Grafana, Tempo, and Prometheus — across two EC2 instances, with a synthetic fake service that emits all four golden signals, distributed traces, and structured logs.

Built to demonstrate SRE fundamentals: SLO tracking, error budget management, DORA metrics, and correlated metrics → logs → traces investigation.

---

## Architecture

```
                    ┌─────────────────────────────────────┐
                    │         Monitoring Server           │
                    │           (t3.large, EIP)           │
                    │                                     │
                    │  Prometheus  :9090                  │◄── scrapes node-exporter :9100
                    │  Grafana     :3000                  │◄── scrapes fake-service  :8080
                    │  Loki        :3100  ◄── OTLP logs   │
                    │  Tempo       :4317  ◄── OTLP traces │
                    │  Alertmanager :9093                 │
                    │  Blackbox    :9115  ──► probes /health
                    │  Pushgateway :9091  ◄── DORA push (GitHub Actions)
                    └─────────────────────────────────────┘
                                      ▲
                    ┌─────────────────┴───────────────────┐
                    │          Application Server         │
                    │            (t3.micro)               │
                    │                                     │
                    │  fake-service      :8080            │
                    │  node-exporter     :9100            │
                    │  otelcol-contrib   :4317 (local)    │
                    └─────────────────────────────────────┘
```

**Traffic flow:**
- Prometheus pulls metrics from `fake-service` (`:8080/metrics`) and `node-exporter` (`:9100`) using private IPs
- `fake-service` pushes traces and logs to the local OTel Collector (`:4317`)
- OTel Collector forwards traces to Tempo and logs to Loki on the monitoring server
- Blackbox Exporter probes `fake-service /health` for availability SLO
- GitHub Actions pushes DORA metrics directly to Pushgateway over HTTP

Both servers share the same VPC (`10.100.0.0/16`). The monitoring server has a static Elastic IP. The app server uses a private IP for all inter-server communication so its ephemeral public IP does not matter for observability.

### Component versions

| Component | Version | Role |
|---|---|---|
| Grafana Enterprise | 13.0.1 | Dashboards, alerting UI |
| Prometheus | 3.5.3 | Metrics collection and alerting |
| Loki | 3.7.2 | Log aggregation |
| Tempo | 3.0.0-rc.1 | Distributed tracing |
| Alertmanager | 0.32.1 | Alert routing to Slack |
| Blackbox Exporter | 0.28.0 | Availability probing |
| Node Exporter | 1.11.1 | OS/infrastructure metrics |
| OTel Collector (contrib) | 0.152.0 | Telemetry fan-out on app server |

---

## Prerequisites

- Terraform >= 1.6
- AWS CLI v2 configured with credentials that can create EC2, VPC, IAM, and SSM resources
- An SSH key pair (`~/.ssh/id_ed25519` by default)
- A [DuckDNS](https://www.duckdns.org) account and subdomain for the Grafana URL
- A Slack incoming webhook URL for alert notifications

---

## Quick Start

### 1. Clone and configure

```bash
git clone https://github.com/Bukunmi0817/LGTM.git
cd LGTM/terraform
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars`:

```hcl
aws_region           = "us-east-1"
instance_type        = "t3.large"      # monitoring server
app_instance_type    = "t3.micro"      # app server
ssh_public_key_path  = "~/.ssh/id_ed25519.pub"
ssh_private_key_path = "~/.ssh/id_ed25519"

# Your current IP — run: curl https://checkip.amazonaws.com
engineer_ips = ["YOUR.IP.ADDRESS/32"]

slack_webhook_url      = "https://hooks.slack.com/services/YOUR/WEBHOOK/URL"
slack_channel          = "#your-alerts-channel"
grafana_admin_password = "ChooseAStrongPassword123!"
duckdns_subdomain      = "your-subdomain"
duckdns_token          = "your-duckdns-token"
metrics_retention      = "15d"
logs_retention         = 360
```

### 2. Deploy

```bash
terraform init && terraform apply
```

Terraform will:
1. Create the VPC, subnets, security groups, and IAM roles
2. Launch both EC2 instances
3. Store private IPs in SSM Parameter Store so each server can find the other
4. SSH into the monitoring server and run `lgtm-stack.sh` — installs and configures Prometheus, Loki, Grafana, Tempo, Alertmanager, and Blackbox Exporter
5. SSH into the app server and run `app-agent.sh` — installs fake-service, Node Exporter, and OTel Collector

Total provisioning time: approximately 8–12 minutes.

### 3. Access

After `apply` completes, Terraform prints the URLs:

```bash
terraform output grafana_url        # http://<EIP>:3000  — admin / <your password>
terraform output prometheus_url     # http://<EIP>:9090
terraform output fake_service_url   # http://<app-ip>:8080
terraform output pushgateway_url    # http://<EIP>:9091
```

Log into Grafana with `admin` and the password you set in `terraform.tfvars`. All datasources (Prometheus, Loki, Tempo) and dashboards are provisioned automatically.

---

## Configuration Reference

All secrets are stored in AWS SSM Parameter Store and fetched at bootstrap time using the instance's IAM role. Nothing sensitive is passed through SSH environment variables or Terraform outputs.

| SSM Parameter | Type | Description |
|---|---|---|
| `/lgtm/slack_webhook_url` | SecureString | Slack incoming webhook |
| `/lgtm/grafana_admin_password` | SecureString | Grafana admin password |
| `/lgtm/monitoring_server_ip` | String | Private IP of monitoring server |
| `/lgtm/app_server_ip` | String | Private IP of app server |

To update a secret after initial deployment:

```bash
aws ssm put-parameter --name /lgtm/slack_webhook_url \
  --value "https://hooks.slack.com/..." --type SecureString --overwrite
```

---

## Dashboard Guide

Navigate to Grafana at `http://<monitoring-ip>:3000`. All dashboards are in the left sidebar under the folder structure that mirrors `dashboards/` in this repo.

### Golden Signals — Start here for service health

**Path:** Reliability → Golden Signals

The primary triage dashboard. Shows all four golden signals for the fake service in one view.

| Panel | What it tells you | When to act |
|---|---|---|
| TRAFFIC — Requests/sec | Request rate broken down by endpoint | Sudden drop means service down or upstream stopped sending |
| ERRORS — Error Rate % | Percentage of 5xx responses | Above 1% is yellow, above 5% is red; check HTTP Errors dashboard next |
| LATENCY — p50 / p95 / p99 | Request duration percentiles | p95 above 500ms triggers the latency SLO alert |
| SATURATION — CPU & Memory | Simulated resource utilisation | Above 80% is yellow, 90% is red |
| SATURATION — Active Connections | Simulated connection count | Tracks with CPU; spikes indicate load bursts |
| TRAFFIC — Rate by Method | GET / POST / PUT breakdown | Unexpected method distribution can indicate misrouted traffic |

The fake service simulates realistic traffic automatically. The `traffic_simulator` background thread sends 5–30 RPS with a day/night load curve, approximately 7% 5xx rate, and occasional error bursts (3% of cycles). You do not need to send traffic manually.

---

### HTTP Errors — Drilling into failures

**Path:** Reliability → HTTP Errors

Use this dashboard after seeing an elevated error rate on Golden Signals.

| Panel | What it tells you |
|---|---|
| 5xx Rate | Raw rate of server errors over time |
| 4xx Rate | Raw rate of client errors over time |
| 5xx by Endpoint | Which route is the source of errors |
| 4xx by Endpoint | Which route is generating bad-request errors |
| Overall Error Ratio | Single aggregate error percentage — use this for SLO comparison |
| Top 5 Endpoints by Error Count | Ranked list of worst offenders |

**Investigation flow:** Golden Signals error spike → HTTP Errors to identify the failing endpoint → Unified Observability to correlate with logs and traces.

---

### SLO & Error Budget — Availability and latency SLO tracking

**Path:** Reliability → SLO & Error Budget

Tracks the two service SLOs over a rolling 30-day window.

| Panel | SLO | Formula |
|---|---|---|
| Availability SLI (30d) | 99.5% | `avg_over_time(probe_success[30d]) * 100` |
| Error Budget Remaining | 0.5% budget = 3.6h/month | `((avg - 0.995) / 0.005) * 100` |
| Latency SLI | 95% of requests < 500ms | Requests hitting the <=500ms bucket / total |
| Error Budget Consumed | Inverse of remaining | Percentage of the 3.6h monthly budget used |
| Burn Rate (1h vs 6h) | — | Fast and slow burn rates with threshold reference lines |

**Note on the 30-day window:** In the first few weeks after deployment, the Error Budget panels will show extreme negative values. This is expected — the 30-day window includes all the downtime before the service was deployed. The values normalise as uptime accumulates. If the service has been running for only 7 days, adjust the Grafana time picker to `now-7d` to see a meaningful budget.

The availability SLO is based on Blackbox Exporter probing the `/health` endpoint. It measures uptime, not application error rate.

---

### DORA Metrics — Delivery performance

**Path:** Delivery → DORA Metrics

Tracks the four DORA metrics from GitHub Actions deployment data pushed to Pushgateway.

| Panel | DORA metric | Description |
|---|---|---|
| Deployments Today | Deployment Frequency | Successful deploys in the last 24 hours |
| Avg Lead Time (30d) | Lead Time for Changes | Mean time from commit to production |
| Change Failure Rate | Change Failure Rate | Percentage of deployments that resulted in a failure |
| Avg MTTR | Mean Time to Restore | Average time to resolve an incident (pushed manually) |
| Lead Time Breakdown | Lead Time | Commit to trigger, trigger to validate, validate to deploy |
| Deploy History | Deployment Frequency | Timeline of all deployment runs with pass/fail status |

Use the **Branch** variable at the top to filter by branch. `main` shows production deployments.

**MTTR tracking:** MTTR is not automatic. After an incident resolves, push the recovery time manually:

```bash
MTTR_SECONDS=3600
curl -X POST http://<monitoring-ip>:9091/metrics/job/incident-mttr \
  --data-binary "incident_mttr_seconds ${MTTR_SECONDS}"
```

---

### Node Exporter — Infrastructure health

**Path:** Infrastructure → Node Exporter

OS-level metrics for the application server, scraped via Node Exporter.

| Panel | Description |
|---|---|
| CPU Usage % | Per-instance CPU utilisation |
| Memory Usage % | Used vs available memory |
| Disk Usage % | Filesystem utilisation |
| Network I/O | Bytes in/out per second |
| Load Average | 1m / 5m / 15m system load |
| Open File Descriptors | File handle usage |

Alert thresholds:
- CPU > 80% for 5 minutes → warning; > 90% → critical
- Memory > 85% for 5 minutes → warning; > 95% → critical
- Disk > 80% → warning; > 90% → critical

---

### Blackbox — External availability probing

**Path:** Infrastructure → Blackbox

Monitors the fake-service health endpoint from the outside, the same way a user would experience it.

| Panel | What is probed |
|---|---|
| Probe Success Rate | `fake-service /health` endpoint uptime |
| HTTP Response Time | Latency of the health probe |
| SSL Certificate Expiry | Days remaining on monitored domain certificates |
| Status Code Distribution | HTTP response codes returned by probed targets |

If `probe_success` drops to 0, the availability SLO is burning. Cross-reference with Golden Signals to determine whether the app is crashing or refusing connections.

---

### Unified Observability — Correlated investigation

**Path:** Observability → Unified

The drill-down dashboard that links metrics, logs, and traces in one view. Designed to walk through an investigation without switching between dashboards.

**Workflow:**
1. **See the spike** in the top panel (5xx rate by endpoint)
2. **Correlate with logs** in the Loki panel — filtered to the same time window automatically
3. **Click a traceID** in a log line — opens the full trace in Tempo
4. **Inspect the trace** — see the HTTP span, the nested `db.query` span, and timing for each stage

This is the intended path when an alert fires: alert → Grafana → Unified → trace → root cause.

---

## Error Budget Policy

The error budget is the mechanism that balances reliability work against feature work. When the budget is healthy, the team ships freely. When the budget is burning, reliability takes priority.

### SLO definitions

| SLO | Target | Error Budget (30d) | Measurement |
|---|---|---|---|
| Availability | 99.5% | 3.6 hours/month | Blackbox `probe_success` on `/health` |
| Latency | 95% of requests < 500ms | 5% of request volume/month | `http_request_duration_seconds_bucket` |
| Change Failure Rate | < 15% | — | Failed deploys / total deploys over 30 days |
| MTTR | < 4 hours | — | Manually pushed after each incident |

### Burn rate alerts

Two alerts fire per SLO, based on the multiwindow burn rate method from the Google SRE Workbook.

**Fast burn — Critical (fires after 2 minutes)**

Fires when the error rate exceeds 14.4x the SLO budget rate. At this pace the remaining monthly budget exhausts in approximately 2 days.

| Alert | Expression | Threshold |
|---|---|---|
| AvailabilitySLOFastBurn | 1h and 5m availability burn rate | > 14.4 * 0.005 |
| LatencySLOFastBurn | 1h and 5m latency violation rate | > 14.4 * 0.05 |

**Slow burn — Warning (fires after 15 minutes)**

Fires when the error rate exceeds 5x the SLO budget rate. At this pace the remaining monthly budget exhausts in approximately 6 days.

| Alert | Expression | Threshold |
|---|---|---|
| AvailabilitySLOSlowBurn | 6h and 1h availability burn rate | > 5 * 0.005 |
| LatencySLOSlowBurn | 6h and 1h latency violation rate | > 5 * 0.05 |

### Budget status and response

| Budget remaining | Status | Required action |
|---|---|---|
| > 50% | Healthy | Ship freely. No restrictions. |
| 25%–50% | Caution | Review recent changes. Increase monitoring cadence. |
| 10%–25% | At risk | Feature freeze on this service. Prioritise reliability fixes. |
| < 10% | Critical | Full reliability sprint. All changes require review. Incident retrospective mandatory. |
| 0% or negative | Exhausted | No new features until budget recovers to 10%. Blameless postmortem required. |

### Fast burn response checklist

When `AvailabilitySLOFastBurn` or `LatencySLOFastBurn` fires in Slack:

1. Open **Golden Signals** — identify whether errors or latency is driving the burn
2. Open **HTTP Errors** — find the failing endpoint and status code
3. Open **Unified Observability** — correlate the spike with logs; click a traceID to inspect the trace
4. Check **DORA Metrics** — if the CFR is elevated, a recent deployment is the likely cause
5. If root cause is not identified within 30 minutes, roll back the most recent deployment
6. After resolution, push MTTR to Pushgateway and add an entry to the incident log

### What does not consume error budget

- Planned maintenance windows (suppress alerts in Alertmanager before the window opens)
- Failures caused by an AWS infrastructure outage (document in the incident log)
- Chaos test traffic generated by `chaos.sh` if announced before the test

---

## Chaos Testing

The app server includes a chaos script for game day exercises and dashboard validation.

```bash
# SSH to the app server
ssh -i ~/.ssh/id_ed25519 ubuntu@$(terraform output -raw app_server_public_ip)

# Trigger 60 consecutive 500 errors — should fire AvailabilitySLOFastBurn
sudo /opt/fake-service/chaos.sh error-burst

# Force slow requests for 5 minutes — should fire LatencySLOFastBurn
sudo /opt/fake-service/chaos.sh latency-spike

# Return to normal traffic pattern
sudo /opt/fake-service/chaos.sh normal

# Check current service health and sample metrics
sudo /opt/fake-service/chaos.sh check
```

Expected dashboard behaviour during `error-burst`:
- Golden Signals ERRORS panel spikes toward 100%
- HTTP Errors 5xx by Endpoint shows the injected endpoint
- Unified Observability logs show `ERROR` level entries with trace IDs
- `AvailabilitySLOFastBurn` alert fires within 2 minutes and posts to Slack

Allow approximately 5 minutes after stopping a chaos scenario for Prometheus rate windows to return to baseline.

---

## DORA Metrics via GitHub Actions

DORA metrics are pushed automatically on every deployment from the `deploy.yml` workflow.

### GitHub Secrets and Variables

After running `terraform apply`, get the values with:

```bash
terraform output github_actions_secrets
```

Add the following to your GitHub repository under **Settings → Secrets and variables → Actions**:

| Name | Type | Value |
|---|---|---|
| `MONITOR_SERVER_IP` | Secret | Elastic IP of the monitoring server |
| `MONITOR_SSH_KEY` | Secret | Contents of `~/.ssh/id_ed25519` (the private key) |
| `DEPLOY_ENABLED` | Variable | `true` to enable SSH-based config deployment |

### What is tracked automatically

Every push to `main` records:

- **Deployment timestamp** — when the deployment ran
- **Total lead time** — time from git commit to deployment confirmed
- **Commit to trigger** — delay between the commit timestamp and pipeline start
- **Trigger to validate** — time spent in validation
- **Validate to deploy** — time from validation passing to deployment confirmed
- **Deployment status** — success (`0`) or failure (`1`)

### Metrics pushed manually

```bash
# After an incident resolves — record MTTR
curl -X POST http://<monitoring-ip>:9091/metrics/job/incident-mttr \
  --data-binary "incident_mttr_seconds 5400"

# After a rollback — record it as a distinct event
curl -X POST http://<monitoring-ip>:9091/metrics/job/rollback \
  --data-binary 'rollback_total{branch="main",reason="high_error_rate"} 1'
```

---

## CI/CD Validation

The `validate.yml` workflow runs on every pull request targeting `main` and blocks merge on any failure:

- `terraform validate` and `terraform fmt` — Terraform syntax and formatting
- `promtool check config` — Prometheus config syntax
- `promtool check rules` — Alert rule syntax and PromQL expression validity
- `yamllint` — YAML formatting for all configs under `configs/`
- JSON schema check — every dashboard JSON must have `uid`, `title`, and `panels` fields
- `shellcheck` — shell script linting for `scripts/*.sh`

This keeps the Change Failure Rate low by catching config errors before they reach the server.

---

## Tear Down

```bash
cd terraform
terraform destroy
```

Removes all AWS resources: both EC2 instances, VPC, security groups, IAM roles, SSM parameters, and the Elastic IP. The Elastic IP address will be different on the next `terraform apply` — update `MONITOR_SERVER_IP` in GitHub Secrets after redeployment.

---

## Troubleshooting

### Services not running after bootstrap

```bash
ssh -i ~/.ssh/id_ed25519 ubuntu@<app-server-ip>
sudo systemctl status fake-service node-exporter otelcol-contrib
sudo journalctl -u fake-service -n 50 --no-pager
```

If `otelcol-contrib` is running but `fake-service` and `node-exporter` are inactive:

```bash
sudo systemctl enable --now fake-service node-exporter
```

### No traces or logs in Grafana

```bash
# On the app server — verify OTel Collector is healthy
curl -s http://localhost:13133/
sudo journalctl -u otelcol-contrib -n 30 --no-pager | grep -E "error|export"

# On the monitoring server — verify Loki is ready
curl -s http://localhost:3100/ready
```

### Prometheus not scraping app server

```bash
# On the monitoring server — check target state
curl -s http://localhost:9090/api/v1/targets | python3 -m json.tool | grep -A5 '"job":"fake-service"'
```

If the target shows `connection refused`, re-run `terraform apply` to ensure the cross-server security group rules are current.

### Pushgateway DORA push timing out from GitHub Actions

Port 9091 must be open to `0.0.0.0/0` in the live AWS security group. Apply any pending Terraform changes:

```bash
cd terraform && terraform apply
```

Then verify the live rule in the AWS console under EC2 → Security Groups → `lgtm-monitoring-sg` → Inbound rules.

### Grafana shows no data

1. Check datasource health: **Connections → Data sources** → test each datasource
2. Confirm Prometheus has data: open `http://<monitoring-ip>:9090/graph` and query `up`
3. Confirm fake-service is emitting metrics: `curl http://<app-ip>:8080/metrics | head -20`
