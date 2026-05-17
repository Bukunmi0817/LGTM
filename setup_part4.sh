#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Part 4 — DORA Metrics & CI/CD Observability
# Run from the ROOT of your observability-platform repo:
#   bash setup_part4.sh
# ─────────────────────────────────────────────────────────────────────────────
set -e

echo ""
echo "┌──────────────────────────────────────────────────────────────┐"
echo "│  Part 4 — DORA Metrics setup                                 │"
echo "└──────────────────────────────────────────────────────────────┘"
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# 1. systemd/pushgateway.service
# ─────────────────────────────────────────────────────────────────────────────
echo "→ [1/7] systemd/pushgateway.service"
cat > systemd/pushgateway.service << 'EOF'
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
  --web.listen-address=:9091 \
  --persistence.file=/var/lib/pushgateway/metrics.db \
  --persistence.interval=5m \
  --log.level=info
Restart=on-failure
RestartSec=5s
NoNewPrivileges=yes
ProtectSystem=strict
ReadWritePaths=/var/lib/pushgateway

[Install]
WantedBy=multi-user.target
EOF

# ─────────────────────────────────────────────────────────────────────────────
# 2. configs/prometheus/prometheus.yml  — append pushgateway scrape job
# ─────────────────────────────────────────────────────────────────────────────
echo "→ [2/7] configs/prometheus/prometheus.yml (appending pushgateway job)"
if grep -q '"pushgateway"' configs/prometheus/prometheus.yml; then
  echo "  ⏭  already contains pushgateway job, skipping"
else
  cat >> configs/prometheus/prometheus.yml << 'EOF'

  - job_name: "pushgateway"
    honor_labels: true
    scrape_interval: 15s
    static_configs:
      - targets: ["localhost:9091"]
        labels:
          environment: "production"
EOF
  echo "  ✅ appended"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 3. configs/prometheus/rules/cicd.yml  — full replacement
#    Metric names updated to match what Pushgateway actually receives.
# ─────────────────────────────────────────────────────────────────────────────
echo "→ [3/7] configs/prometheus/rules/cicd.yml"
cat > configs/prometheus/rules/cicd.yml << 'EOF'
groups:
  - name: cicd.rules
    rules:

      # Fires immediately when the most recent deployment on any branch failed.
      # github_last_deploy_status is overwritten each run: 0=success, 1=failure.
      - alert: DeploymentFailed
        expr: github_last_deploy_status == 1
        for: 0m
        labels:
          severity: critical
          metric: "deployment_failure"
        annotations:
          summary: "Deployment failed on {{ $labels.branch }} ({{ $labels.workflow }})"
          description: >
            The most recent deployment on branch {{ $labels.branch }} failed
            (commit: {{ $labels.commit }}). CFR is incrementing.
            Check GitHub Actions logs and consider a rollback.
          dashboard_url: "http://13.61.147.12:3000/d/dora-metrics/dora-metrics"
          runbook_url: "https://github.com/Bukunmi0817/LGTM/blob/main/runbooks/cfr_threshold.md"

      # Fires when rolling 30-day CFR exceeds 15% SLO threshold for 5 minutes.
      # github_deploy_timestamp_seconds VALUE = unix timestamp of each run.
      # Filtering by value (> time() - 2592000) gives us only the last 30 days.
      - alert: HighChangeFailureRate
        expr: |
          (
            count(github_deploy_timestamp_seconds{status="failure"} > (time() - 2592000))
            /
            count(github_deploy_timestamp_seconds > (time() - 2592000))
          ) * 100 > 15
        for: 5m
        labels:
          severity: critical
          metric: "change_failure_rate"
        annotations:
          summary: "Change Failure Rate exceeds 15% SLO threshold"
          description: >
            CFR is {{ $value | printf "%.1f" }}% over the last 30 days.
            SLO threshold: 15%. A reliability sprint may be required.
          dashboard_url: "http://13.61.147.12:3000/d/dora-metrics/dora-metrics"
          runbook_url: "https://github.com/Bukunmi0817/LGTM/blob/main/runbooks/cfr_threshold.md"

      # Fires when the last recorded incident MTTR exceeded 4 hours.
      # Push MTTR to Pushgateway after an incident resolves:
      #   curl -X POST http://localhost:9091/metrics/job/incident-mttr \
      #     --data-binary "incident_mttr_seconds SECONDS"
      - alert: MTTRExceeded
        expr: incident_mttr_seconds > 14400
        for: 0m
        labels:
          severity: warning
          metric: "mttr"
        annotations:
          summary: "MTTR exceeded 4-hour SLO threshold"
          description: >
            Last incident MTTR was {{ $value | humanizeDuration }}.
            SLO target: under 4 hours. Document where manual steps added time.
          dashboard_url: "http://13.61.147.12:3000/d/dora-metrics/dora-metrics"
          runbook_url: "https://github.com/Bukunmi0817/LGTM/blob/main/runbooks/mttr_exceeded.md"
EOF

# ─────────────────────────────────────────────────────────────────────────────
# 4. dashboards/delivery/dora-metrics.json  — full replacement via Python
#    Using Python so json.dumps guarantees valid JSON formatting.
# ─────────────────────────────────────────────────────────────────────────────
echo "→ [4/7] dashboards/delivery/dora-metrics.json"
cat > /tmp/gen_dashboard.py << 'PYEOF'
import json

dashboard = {
  "title": "DORA Metrics",
  "uid": "dora-metrics",
  "tags": ["delivery", "dora", "cicd"],
  "timezone": "browser",
  "schemaVersion": 38,
  "refresh": "5m",
  "time": {"from": "now-30d", "to": "now"},
  "templating": {
    "list": [{
      "name": "branch", "label": "Branch", "type": "query",
      "datasource": {"type": "prometheus", "uid": "prometheus"},
      "query": "label_values(github_deploy_timestamp_seconds, branch)",
      "current": {"value": "main", "text": "main"},
      "multi": False, "includeAll": True, "allValue": ".*",
      "refresh": 2, "sort": 1
    }]
  },
  "panels": [

    # ── Row 1: four summary stats ─────────────────────────────────────────────
    {
      "id": 1, "title": "Deployments Today",
      "description": "Successful deployments in the last 24 hours.",
      "type": "stat",
      "gridPos": {"h": 6, "w": 6, "x": 0, "y": 0},
      "datasource": {"type": "prometheus", "uid": "prometheus"},
      "targets": [{"refId": "A",
        "expr": 'count(github_deploy_timestamp_seconds{status="success",branch=~"$branch"} > (time() - 86400)) or vector(0)',
        "legendFormat": "Today"}],
      "fieldConfig": {"defaults": {"unit": "short", "thresholds": {"mode": "absolute", "steps": [
        {"color": "red", "value": None}, {"color": "yellow", "value": 1}, {"color": "green", "value": 3}
      ]}}},
      "options": {"colorMode": "background", "graphMode": "none", "justifyMode": "center",
                  "reduceOptions": {"calcs": ["lastNotNull"]}}
    },
    {
      "id": 2, "title": "DORA Performance Level",
      "description": "Deployment frequency classification per DORA benchmarks (7-day rolling average). Elite = multiple/day, High = daily, Medium = weekly, Low = monthly.",
      "type": "stat",
      "gridPos": {"h": 6, "w": 6, "x": 6, "y": 0},
      "datasource": {"type": "prometheus", "uid": "prometheus"},
      "targets": [{"refId": "A",
        "expr": '(count(github_deploy_timestamp_seconds{status="success",branch=~"$branch"} > (time() - 604800)) or vector(0)) / 7',
        "legendFormat": "Deploys/day (7d avg)"}],
      "fieldConfig": {"defaults": {"unit": "short", "decimals": 2, "mappings": [
        {"type": "range", "options": {"from": 0,    "to": 0.03, "result": {"text": "🔴  Low (< monthly)",      "color": "red"}}},
        {"type": "range", "options": {"from": 0.03, "to": 0.14, "result": {"text": "🟡  Medium (weekly)",       "color": "yellow"}}},
        {"type": "range", "options": {"from": 0.14, "to": 1,    "result": {"text": "🔵  High (daily)",          "color": "blue"}}},
        {"type": "range", "options": {"from": 1,    "to": 9999, "result": {"text": "🟢  Elite (multiple/day)", "color": "green"}}}
      ]}},
      "options": {"colorMode": "background", "reduceOptions": {"calcs": ["lastNotNull"]}}
    },
    {
      "id": 3, "title": "Change Failure Rate (30d)",
      "description": "% of deployments causing failures in the last 30 days. SLO threshold: < 15%. DORA Elite: < 5%.",
      "type": "stat",
      "gridPos": {"h": 6, "w": 6, "x": 12, "y": 0},
      "datasource": {"type": "prometheus", "uid": "prometheus"},
      "targets": [{"refId": "A",
        "expr": '(count(github_deploy_timestamp_seconds{status="failure",branch=~"$branch"} > (time() - 2592000)) or vector(0)) / (count(github_deploy_timestamp_seconds{branch=~"$branch"} > (time() - 2592000)) or vector(1)) * 100',
        "legendFormat": "CFR %"}],
      "fieldConfig": {"defaults": {"unit": "percent", "decimals": 1, "thresholds": {"mode": "absolute", "steps": [
        {"color": "green", "value": None}, {"color": "yellow", "value": 5}, {"color": "red", "value": 15}
      ]}}},
      "options": {"colorMode": "background", "reduceOptions": {"calcs": ["lastNotNull"]}}
    },
    {
      "id": 4, "title": "Mean Time to Restore",
      "description": "Alert-fire to alert-resolved. SLO: < 4 hours. Push after incident: curl -X POST http://localhost:9091/metrics/job/incident-mttr --data-binary 'incident_mttr_seconds SECONDS'",
      "type": "stat",
      "gridPos": {"h": 6, "w": 6, "x": 18, "y": 0},
      "datasource": {"type": "prometheus", "uid": "prometheus"},
      "targets": [{"refId": "A", "expr": "incident_mttr_seconds or vector(0)", "legendFormat": "MTTR"}],
      "fieldConfig": {"defaults": {"unit": "s", "thresholds": {"mode": "absolute", "steps": [
        {"color": "green", "value": None}, {"color": "yellow", "value": 3600}, {"color": "red", "value": 14400}
      ]}, "mappings": [{"type": "value", "options": {"0": {"text": "No incidents recorded"}}}]}},
      "options": {"colorMode": "background", "reduceOptions": {"calcs": ["lastNotNull"]}}
    },

    # ── Row 2: deployment history + CFR trend ─────────────────────────────────
    {
      "id": 5, "title": "Deployment History",
      "description": "Cumulative total. Each step up = one deployment pushed to Pushgateway. Green = success, red = failure.",
      "type": "timeseries",
      "gridPos": {"h": 8, "w": 12, "x": 0, "y": 6},
      "datasource": {"type": "prometheus", "uid": "prometheus"},
      "targets": [
        {"refId": "A", "expr": 'count(github_deploy_timestamp_seconds{status="success",branch=~"$branch"}) or vector(0)', "legendFormat": "Successful Deployments"},
        {"refId": "B", "expr": 'count(github_deploy_timestamp_seconds{status="failure",branch=~"$branch"}) or vector(0)', "legendFormat": "Failed Deployments"}
      ],
      "fieldConfig": {
        "defaults": {"unit": "short", "custom": {"lineInterpolation": "stepAfter", "fillOpacity": 10}},
        "overrides": [
          {"matcher": {"id": "byName", "options": "Failed Deployments"},
           "properties": [{"id": "color", "value": {"mode": "fixed", "fixedColor": "red"}}]},
          {"matcher": {"id": "byName", "options": "Successful Deployments"},
           "properties": [{"id": "color", "value": {"mode": "fixed", "fixedColor": "green"}}]}
        ]
      }
    },
    {
      "id": 6, "title": "Change Failure Rate — Trend (30d rolling)",
      "description": "Rolling CFR over time. Threshold lines at 5% (DORA Elite boundary) and 15% (our SLO). Alert fires when crossing 15%.",
      "type": "timeseries",
      "gridPos": {"h": 8, "w": 12, "x": 12, "y": 6},
      "datasource": {"type": "prometheus", "uid": "prometheus"},
      "targets": [{"refId": "A",
        "expr": '(count(github_deploy_timestamp_seconds{status="failure",branch=~"$branch"} > (time() - 2592000)) or vector(0)) / (count(github_deploy_timestamp_seconds{branch=~"$branch"} > (time() - 2592000)) or vector(1)) * 100',
        "legendFormat": "CFR % (30d rolling)"}],
      "fieldConfig": {"defaults": {"unit": "percent",
        "custom": {"thresholdsStyle": {"mode": "line+area"}, "fillOpacity": 5},
        "thresholds": {"mode": "absolute", "steps": [
          {"color": "green", "value": None}, {"color": "yellow", "value": 5}, {"color": "red", "value": 15}
        ]}}}
    },

    # ── Row 3: lead time sub-intervals + total trend ───────────────────────────
    {
      "id": 7, "title": "Lead Time — Sub-interval Breakdown",
      "description": "Stacked: where time is actually spent. ① Commit→Trigger (pre-pipeline delay). ② Trigger→Validation (CI speed). ③ Validation→Deploy (CD speed).",
      "type": "timeseries",
      "gridPos": {"h": 9, "w": 12, "x": 0, "y": 14},
      "datasource": {"type": "prometheus", "uid": "prometheus"},
      "targets": [
        {"refId": "A", "expr": 'avg(github_deploy_commit_to_trigger_seconds{branch=~"$branch"}) or vector(0)',  "legendFormat": "① Commit → Pipeline Trigger"},
        {"refId": "B", "expr": 'avg(github_deploy_trigger_to_build_seconds{branch=~"$branch"}) or vector(0)',  "legendFormat": "② Trigger → Validation Complete"},
        {"refId": "C", "expr": 'avg(github_deploy_build_to_deploy_seconds{branch=~"$branch"}) or vector(0)',   "legendFormat": "③ Validation → Deploy Confirmed"}
      ],
      "fieldConfig": {"defaults": {"unit": "s",
        "custom": {"stacking": {"mode": "normal", "group": "A"}, "fillOpacity": 40, "lineWidth": 0}}}
    },
    {
      "id": 8, "title": "Lead Time for Changes — Total Trend",
      "description": "Avg total lead time (commit to deploy confirmed). DORA Elite: < 1h. High: < 1d. Medium: < 1w. Low: > 1w.",
      "type": "timeseries",
      "gridPos": {"h": 9, "w": 12, "x": 12, "y": 14},
      "datasource": {"type": "prometheus", "uid": "prometheus"},
      "targets": [{"refId": "A",
        "expr": 'avg(github_deploy_lead_time_seconds{branch=~"$branch"}) or vector(0)',
        "legendFormat": "Avg Lead Time"}],
      "fieldConfig": {"defaults": {"unit": "s",
        "custom": {"thresholdsStyle": {"mode": "line"}},
        "thresholds": {"mode": "absolute", "steps": [
          {"color": "green", "value": None}, {"color": "blue", "value": 3600},
          {"color": "yellow", "value": 86400}, {"color": "red", "value": 604800}
        ]}}}
    },

    # ── Row 4: last deploy status + MTTR history ──────────────────────────────
    {
      "id": 9, "title": "Last Deployment Status",
      "description": "Status of the most recent deployment per branch. Drives DeploymentFailed alert when value = 1.",
      "type": "stat",
      "gridPos": {"h": 5, "w": 6, "x": 0, "y": 23},
      "datasource": {"type": "prometheus", "uid": "prometheus"},
      "targets": [{"refId": "A",
        "expr": 'github_last_deploy_status{branch=~"$branch"} or vector(0)',
        "legendFormat": "{{ branch }}"}],
      "fieldConfig": {"defaults": {"mappings": [
        {"type": "value", "options": {"0": {"text": "✅  Success", "color": "green"}}},
        {"type": "value", "options": {"1": {"text": "❌  Failed",  "color": "red"}}}
      ]}},
      "options": {"colorMode": "background", "reduceOptions": {"calcs": ["lastNotNull"]}}
    },
    {
      "id": 10, "title": "MTTR — Incident History",
      "description": "Each bar = one recorded incident. Push after resolution: curl -X POST http://localhost:9091/metrics/job/incident-mttr --data-binary 'incident_mttr_seconds SECONDS'",
      "type": "timeseries",
      "gridPos": {"h": 5, "w": 18, "x": 6, "y": 23},
      "datasource": {"type": "prometheus", "uid": "prometheus"},
      "targets": [{"refId": "A", "expr": "incident_mttr_seconds or vector(0)", "legendFormat": "MTTR (seconds)"}],
      "fieldConfig": {"defaults": {"unit": "s",
        "custom": {"drawStyle": "bars", "fillOpacity": 80, "lineWidth": 0},
        "thresholds": {"mode": "absolute", "steps": [
          {"color": "green", "value": None}, {"color": "yellow", "value": 3600}, {"color": "red", "value": 14400}
        ]}}}
    }
  ]
}

with open("dashboards/delivery/dora-metrics.json", "w") as f:
    json.dump(dashboard, f, indent=2)
print("  ✅ dashboard written")
PYEOF
python3 /tmp/gen_dashboard.py

# ─────────────────────────────────────────────────────────────────────────────
# 5. docs/toil-analysis.md
# ─────────────────────────────────────────────────────────────────────────────
echo "→ [5/7] docs/toil-analysis.md"
mkdir -p docs
cat > docs/toil-analysis.md << 'EOF'
# Toil Analysis — DORA Metrics Pipeline

## What Is Toil?

Toil is repetitive, manual, automatable work that scales linearly with load
and produces no lasting value. Per Google SRE: if a runbook describes how to
do it and a machine could follow those same instructions, it is toil.

---

## Toil 1: Manual MTTR Recording

**What it is**: After every incident resolves, an engineer must manually
calculate `resolution_time - alert_fire_time` and push the result to Pushgateway:

```bash
curl -X POST http://localhost:9091/metrics/job/incident-mttr \
  --data-binary "incident_mttr_seconds $((RESOLVE_TS - FIRE_TS))"
```

**Why it's toil**: Requires human memory during a stressful post-incident
moment, is error-prone (wrong timestamps), and gets skipped under pressure —
leaving MTTR data incomplete and the `MTTRExceeded` alert unreliable.

**Proposed automation**: An Alertmanager webhook receiver (small Python service)
that records the firing timestamp on receipt, then on a `resolved` webhook
auto-calculates the delta and pushes `incident_mttr_seconds` to Pushgateway.
MTTR tracking becomes entirely zero-touch.

**Status**: ⏳ Partially implemented. Pushgateway is live. The curl command is
documented in every alert runbook. The webhook receiver is the next target.

---

## Toil 2: Stale Pushgateway Metric Accumulation

**What it is**: Every deployment creates a new Pushgateway entry (unique `runid`
per run). These accumulate indefinitely. After 6 months of daily deployments
you have 180+ orphaned metric families consuming memory with no automatic expiry.

**Why it's toil**: Someone must periodically SSH in and call the Pushgateway
DELETE API to clean up old entries — or accept degrading performance.

**Proposed automation**: A systemd timer running this weekly:

```bash
#!/bin/bash
# /usr/local/bin/cleanup-pushgateway.sh
CUTOFF=$(($(date +%s) - 7776000))   # 90 days ago

curl -s http://localhost:9091/api/v1/metrics | python3 -c "
import json, sys
for m in json.load(sys.stdin)['data']:
    if float(m.get('push_time_seconds', 0)) < ${CUTOFF}:
        labels = '/'.join(f'{k}/{v}' for k,v in m['labels'].items())
        print(labels)
" | while read labels; do
  curl -s -X DELETE "http://localhost:9091/metrics/job/${labels}"
done
```

**Status**: ✅ Script ready. Pending `systemd/pushgateway-cleanup.timer`
to schedule weekly execution.

---

## Toil Already Eliminated by This Pipeline

Before this pipeline, engineers manually ran `promtool` and `yamllint` before
every commit and manually checked Grafana post-deploy. Both are now automated:

- **Config validation** runs in CI on every push — broken configs are rejected
  before they reach the server.
- **Post-deploy health check** hits Grafana `/api/health` automatically — a
  non-200 marks the workflow failed and increments CFR.

**This toil is fully eliminated.**
EOF

# ─────────────────────────────────────────────────────────────────────────────
# 6. .github/workflows/deploy.yml — 3 patches
#
# Strategy: write old/new strings to temp files with cat heredoc (no shell
# expansion, no Python escaping), then apply with a Python one-liner.
# ─────────────────────────────────────────────────────────────────────────────
echo "→ [6/7] .github/workflows/deploy.yml (3 patches)"

# ── Patch 6a: add "Record pipeline start time" before checkout ───────────────
cat > /tmp/old_6a.txt << 'EOF'
    steps:
      # ----------------------------------------------------------------
      # Step 1: Check out the repository
EOF

cat > /tmp/new_6a.txt << 'EOF'
    steps:
      - name: Record pipeline start time
        run: echo "PIPELINE_START=$(date +%s)" >> $GITHUB_ENV

      # ----------------------------------------------------------------
      # Step 1: Check out the repository
EOF

python3 - << 'PYEOF'
old = open('/tmp/old_6a.txt').read().rstrip('\n')
new = open('/tmp/new_6a.txt').read().rstrip('\n')
f   = '.github/workflows/deploy.yml'
c   = open(f).read()
if old in c:
    open(f, 'w').write(c.replace(old, new, 1))
    print("  ✅ 6a: pipeline start timestamp added")
elif "Record pipeline start time" in c:
    print("  ⏭  6a: already applied")
else:
    print("  ❌ 6a: patch target not found — apply manually")
PYEOF

# ── Patch 6b: add "Mark validation phase complete" after yamllint ────────────
cat > /tmp/old_6b.txt << 'EOF'
          yamllint -c .yamllint configs/
          echo "All YAML configs valid"

      # ----------------------------------------------------------------
      # Step 3: Deploy configs to the server via SSH
EOF

cat > /tmp/new_6b.txt << 'EOF'
          yamllint -c .yamllint configs/
          echo "All YAML configs valid"

      - name: Mark validation phase complete
        if: always()
        run: echo "VALIDATION_END=$(date +%s)" >> $GITHUB_ENV

      # ----------------------------------------------------------------
      # Step 3: Deploy configs to the server via SSH
EOF

python3 - << 'PYEOF'
old = open('/tmp/old_6b.txt').read().rstrip('\n')
new = open('/tmp/new_6b.txt').read().rstrip('\n')
f   = '.github/workflows/deploy.yml'
c   = open(f).read()
if old in c:
    open(f, 'w').write(c.replace(old, new, 1))
    print("  ✅ 6b: validation end timestamp added")
elif "Mark validation phase complete" in c:
    print("  ⏭  6b: already applied")
else:
    print("  ❌ 6b: patch target not found — apply manually")
PYEOF

# ── Patch 6c: replace "Record deployment timestamp" with DORA metrics push ───
cat > /tmp/old_6c.txt << 'EOF'
      # ----------------------------------------------------------------
      # Step 5: Record deployment metadata
      # This creates a metric we can use to track deployment timestamps.
      # ----------------------------------------------------------------
      - name: Record deployment timestamp
        if: always()
        run: |
          echo "Deployment completed at: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
          echo "Status: ${{ job.status }}"
          echo "Commit: ${{ github.sha }}"
          echo "Branch: ${{ github.ref_name }}"
          echo "Actor: ${{ github.actor }}"
EOF

cat > /tmp/new_6c.txt << 'EOF'
      # ----------------------------------------------------------------
      # Step 5: Push DORA metrics to Pushgateway
      # Runs even on failure (always) so CFR data is always captured.
      # Per-run metrics: unique Pushgateway path per RUN_ID — history builds up.
      # Latest-state metrics: overwritten each run — drives DeploymentFailed alert.
      # ----------------------------------------------------------------
      - name: Push DORA metrics to Pushgateway
        if: ${{ always() && vars.DEPLOY_ENABLED == 'true' }}
        env:
          RUN_ID:     ${{ github.run_id }}
          BRANCH:     ${{ github.ref_name }}
          REPO:       ${{ github.repository }}
          WORKFLOW:   ${{ github.workflow }}
          COMMIT_SHA: ${{ github.sha }}
          JOB_STATUS: ${{ job.status }}
        run: |
          DEPLOY_END=$(date +%s)
          COMMIT_TIME=$(git log -1 --format=%ct)

          # Fallback if an early failure meant timestamps were never recorded
          PIPELINE_START="${PIPELINE_START:-$COMMIT_TIME}"
          VALIDATION_END="${VALIDATION_END:-$PIPELINE_START}"

          # Calculate all four DORA lead time sub-intervals
          LEAD_TIME_TOTAL=$((DEPLOY_END - COMMIT_TIME))
          LEAD_TIME_COMMIT_TO_TRIGGER=$((PIPELINE_START - COMMIT_TIME))
          LEAD_TIME_TRIGGER_TO_BUILD=$((VALIDATION_END - PIPELINE_START))
          LEAD_TIME_BUILD_TO_DEPLOY=$((DEPLOY_END - VALIDATION_END))

          # 0=success, 1=failure — drives the DeploymentFailed alert
          if [ "$JOB_STATUS" = "success" ]; then STATUS_VALUE=0; else STATUS_VALUE=1; fi

          # Per-run metrics (unique job path per RUN_ID — history accumulates in Pushgateway)
          # NOTE: VALUE of github_deploy_timestamp_seconds IS the unix timestamp.
          # This lets PromQL filter by time window: metric > (time() - 86400)
          cat > /tmp/dora_run.txt << METRICS
          # HELP github_deploy_timestamp_seconds Unix timestamp of this deployment run
          # TYPE github_deploy_timestamp_seconds gauge
          github_deploy_timestamp_seconds{runid="${RUN_ID}",branch="${BRANCH}",status="${JOB_STATUS}",repo="${REPO}"} ${DEPLOY_END}
          # HELP github_deploy_lead_time_seconds Total lead time from commit to deploy confirmed
          # TYPE github_deploy_lead_time_seconds gauge
          github_deploy_lead_time_seconds{runid="${RUN_ID}",branch="${BRANCH}"} ${LEAD_TIME_TOTAL}
          # HELP github_deploy_commit_to_trigger_seconds Commit to pipeline trigger
          # TYPE github_deploy_commit_to_trigger_seconds gauge
          github_deploy_commit_to_trigger_seconds{runid="${RUN_ID}",branch="${BRANCH}"} ${LEAD_TIME_COMMIT_TO_TRIGGER}
          # HELP github_deploy_trigger_to_build_seconds Trigger to validation complete
          # TYPE github_deploy_trigger_to_build_seconds gauge
          github_deploy_trigger_to_build_seconds{runid="${RUN_ID}",branch="${BRANCH}"} ${LEAD_TIME_TRIGGER_TO_BUILD}
          # HELP github_deploy_build_to_deploy_seconds Validation to deploy confirmed
          # TYPE github_deploy_build_to_deploy_seconds gauge
          github_deploy_build_to_deploy_seconds{runid="${RUN_ID}",branch="${BRANCH}"} ${LEAD_TIME_BUILD_TO_DEPLOY}
          METRICS

          # Latest-state metrics (same path each run — overwrites previous)
          cat > /tmp/dora_latest.txt << LATEST
          # HELP github_last_deploy_status Most recent deploy: 0=success 1=failure
          # TYPE github_last_deploy_status gauge
          github_last_deploy_status{branch="${BRANCH}",workflow="${WORKFLOW}",commit="${COMMIT_SHA}"} ${STATUS_VALUE}
          # HELP github_last_deploy_timestamp_seconds Timestamp of most recent deployment
          # TYPE github_last_deploy_timestamp_seconds gauge
          github_last_deploy_timestamp_seconds{branch="${BRANCH}"} ${DEPLOY_END}
          LATEST

          # Upload both files and push to Pushgateway on the server
          scp -i ~/.ssh/deploy_key /tmp/dora_run.txt /tmp/dora_latest.txt \
            ${{ secrets.SSH_USER }}@${{ secrets.SERVER_IP }}:/tmp/

          ssh -i ~/.ssh/deploy_key ${{ secrets.SSH_USER }}@${{ secrets.SERVER_IP }} "
            curl -sf --data-binary @/tmp/dora_run.txt \
              http://localhost:9091/metrics/job/github-deploy/runid/${RUN_ID} &&
            curl -sf --data-binary @/tmp/dora_latest.txt \
              http://localhost:9091/metrics/job/github-deploy-latest/branch/${BRANCH} &&
            rm -f /tmp/dora_run.txt /tmp/dora_latest.txt &&
            echo 'DORA metrics pushed to Pushgateway'
          "

          echo "--- Deployment summary ---"
          echo "  Status:             ${JOB_STATUS}"
          echo "  Commit:             ${COMMIT_SHA}"
          echo "  Total lead time:    ${LEAD_TIME_TOTAL}s"
          echo "  Commit → Trigger:   ${LEAD_TIME_COMMIT_TO_TRIGGER}s"
          echo "  Trigger → Validate: ${LEAD_TIME_TRIGGER_TO_BUILD}s"
          echo "  Validate → Deploy:  ${LEAD_TIME_BUILD_TO_DEPLOY}s"
EOF

python3 - << 'PYEOF'
old = open('/tmp/old_6c.txt').read().rstrip('\n')
new = open('/tmp/new_6c.txt').read().rstrip('\n')
f   = '.github/workflows/deploy.yml'
c   = open(f).read()
if old in c:
    open(f, 'w').write(c.replace(old, new, 1))
    print("  ✅ 6c: DORA metrics push step added")
elif "Push DORA metrics to Pushgateway" in c:
    print("  ⏭  6c: already applied")
else:
    print("  ❌ 6c: patch target not found — apply manually")
PYEOF

# ─────────────────────────────────────────────────────────────────────────────
# 7. terraform/main.tf — add Pushgateway provisioners before closing brace
# ─────────────────────────────────────────────────────────────────────────────
echo "→ [7/7] terraform/main.tf (adding Pushgateway provisioners)"

cat > /tmp/old_7.txt << 'EOF'
      "chmod +x /tmp/obs-setup/install.sh",
      "sudo /tmp/obs-setup/install.sh",
    ]
  }
}
EOF

cat > /tmp/new_7.txt << 'EOF'
      "chmod +x /tmp/obs-setup/install.sh",
      "sudo /tmp/obs-setup/install.sh",
    ]
  }

  # ----------------------------------------------------------------
  # Pushgateway: receives DORA metrics pushed from GitHub Actions
  # and exposes them on :9091 for Prometheus to scrape.
  # ----------------------------------------------------------------
  provisioner "file" {
    source      = "../systemd/pushgateway.service"
    destination = "/tmp/obs-setup/systemd/pushgateway.service"
  }

  provisioner "remote-exec" {
    inline = [
      "wget -q https://github.com/prometheus/pushgateway/releases/download/v1.9.0/pushgateway-1.9.0.linux-amd64.tar.gz -O /tmp/pushgateway.tar.gz",
      "tar xzf /tmp/pushgateway.tar.gz -C /tmp/",
      "sudo mv /tmp/pushgateway-1.9.0.linux-amd64/pushgateway /usr/local/bin/pushgateway",
      "sudo mkdir -p /var/lib/pushgateway",
      "sudo chown prometheus:prometheus /var/lib/pushgateway",
      "sudo cp /tmp/obs-setup/systemd/pushgateway.service /etc/systemd/system/pushgateway.service",
      "sudo systemctl daemon-reload",
      "sudo systemctl enable --now pushgateway",
      "echo 'Pushgateway running on :9091'"
    ]
  }
}
EOF

python3 - << 'PYEOF'
old = open('/tmp/old_7.txt').read().rstrip('\n')
new = open('/tmp/new_7.txt').read().rstrip('\n')
f   = 'terraform/main.tf'
c   = open(f).read()
if old in c:
    open(f, 'w').write(c.replace(old, new, 1))
    print("  ✅ main.tf: Pushgateway provisioners added")
elif "pushgateway" in c:
    print("  ⏭  main.tf: Pushgateway already present")
else:
    print("  ❌ main.tf: patch target not found — apply manually")
PYEOF

# ─────────────────────────────────────────────────────────────────────────────
# Done — verify and push
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "┌──────────────────────────────────────────────────────────────┐"
echo "│  All done. Run these checks before pushing:                  │"
echo "│                                                              │"
echo "│  promtool check config configs/prometheus/prometheus.yml     │"
echo "│  promtool check rules  configs/prometheus/rules/cicd.yml     │"
echo "│  python3 -c \"import json; json.load(open(                 │"
echo "│    'dashboards/delivery/dora-metrics.json')); print('OK')\"  │"
echo "│                                                              │"
echo "│  git add .                                                   │"
echo "│  git commit -m 'feat: Part 4 DORA metrics pipeline'         │"
echo "│  git push                                                    │"
echo "└──────────────────────────────────────────────────────────────┘"
echo ""
