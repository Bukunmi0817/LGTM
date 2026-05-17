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
