# SLO Burn Rate Alerts

Covers: `SLOFastBurn`, `SLOSlowBurn`, `LatencySLOFastBurn`

> **Background:** The service has a 99% availability SLO. The error budget is 1% of requests per 30 days (~3.6 hours of full outage equivalent). Burn rate multipliers express how fast the budget is being consumed relative to the sustainable rate — 1x means exactly on budget, 14.4x means the full budget exhausts in ~2 hours.

---

### SLOFastBurn

| Field | Value |
|---|---|
| Severity | critical |
| Threshold | Error rate > 14.4× budget (>14.4% of requests failing) in both 1h and 5m windows |
| Fire duration | 2 minutes |
| Budget impact | Entire 30-day budget exhausts in ~2 hours at this rate |

**What it means**
This is a P1 incident. More than 1 in 7 requests are failing right now and have been for at least 2 minutes. The error budget will be completely gone within hours. Drop everything.

**Diagnose**

```bash
# Check current error rate in Prometheus
curl -sG http://localhost:9090/api/v1/query \
  --data-urlencode 'query=job:http_request_errors:rate5m' | python3 -m json.tool
```

In Grafana:
1. Open the **SLO / Error Budget** dashboard — the "Budget Remaining" panel shows how much time is left
2. Open **Explore → Tempo** — filter traces by `status=error` to find which endpoints are failing
3. Check the **Golden Signals** dashboard — look at the error rate panel for when the spike started

```bash
# On the app server, check fake-service logs
sudo journalctl -u fake-service --since "15 minutes ago" | grep -i "error\|exception\|500"

# Check if a chaos script is running
sudo ps aux | grep chaos
sudo /opt/fake-service/chaos.sh check
```

**Resolve**

1. If a chaos script triggered this:
   ```bash
   sudo /opt/fake-service/chaos.sh normal
   ```
2. If caused by a recent deployment, rollback immediately:
   ```bash
   git revert HEAD && git push origin main
   ```
3. If a specific endpoint is failing, take it out of service temporarily using a feature flag or by returning a graceful error
4. Restart fake-service if it appears to be in a bad state:
   ```bash
   sudo systemctl restart fake-service
   ```

**After resolving**
- Confirm the alert resolves in Alertmanager (allow ~5 minutes for the 5m rate window to drain)
- Push MTTR to Pushgateway once confirmed stable
- File a postmortem within 24 hours

---

### SLOSlowBurn

| Field | Value |
|---|---|
| Severity | warning |
| Threshold | Error rate > 5× budget (>5% of requests failing) in both 6h and 1h windows |
| Fire duration | 15 minutes |
| Budget impact | 30-day budget exhausts in ~6 days at this rate |

**What it means**
The error rate has been elevated for hours, not minutes. This is not an acute incident but a slow bleed. If the trend continues for several days the entire monthly error budget will be consumed before the SLO window resets.

**Diagnose**

The longer windows mean you have more time to investigate carefully:

```bash
# Check the 6h rate
curl -sG http://localhost:9090/api/v1/query \
  --data-urlencode 'query=job:http_request_errors:rate6h' | python3 -m json.tool
```

In Grafana, set the time range to "Last 24 hours" on the SLO dashboard to see when the slow elevation began.

Common causes of slow burn (as opposed to fast burn):
- A subset of requests hitting a consistently broken code path (e.g. a specific user action or query parameter)
- A dependency returning errors intermittently without full outage
- A background job retrying failed operations and recording each retry as an error

**Resolve**

- Identify the specific error class from Loki logs and Tempo traces
- Fix the underlying issue and deploy
- If the fix cannot be shipped immediately, consider adding retries or client-side fallback to reduce the visible error rate while the fix is prepared
- Monitor the 6h burn rate after the fix — it takes a full 6 hours for the window to fully reflect the improvement

**Escalate if** the 6h burn rate climbs above 14.4× (which will also trigger `SLOFastBurn`).

---

### LatencySLOFastBurn

| Field | Value |
|---|---|
| Severity | critical |
| Threshold | p95 latency > 500ms in both 1h and 5m windows |
| Fire duration | 2 minutes |
| SLO | 95% of requests must complete under 500ms |

**What it means**
At least 5% of requests are taking longer than 500ms and have been for at least 2 minutes across both a short and a long window — so this is not a transient spike. The latency SLO is actively being violated.

**Diagnose**

```bash
# Current p95 from Prometheus
curl -sG http://localhost:9090/api/v1/query \
  --data-urlencode 'query=histogram_quantile(0.95, sum by(le) (rate(http_request_duration_seconds_bucket[5m])))' \
  | python3 -m json.tool
```

In Grafana:
1. Open the **Golden Signals** dashboard — the latency panel shows p50/p95/p99 over time. Identify when the degradation started.
2. Open **Explore → Tempo** and search for long-running traces. Sort by duration descending. The slowest traces will show which service call or code path is the bottleneck.

Common causes:
- CPU saturation on the app server causing request queuing (check `CPUWarning` / `CPUCritical` simultaneously)
- A downstream dependency slowing down (external HTTP call, database)
- Memory pressure causing GC pauses in the Python service
- A specific endpoint with an inefficient operation

**Resolve**

1. If CPU is also elevated, follow the `CPUCritical` runbook first — CPU saturation is often the root cause of latency degradation
2. If the slow path is identifiable from traces, patch it or add a timeout to isolate the slow dependency
3. Restart `fake-service` if thread pool exhaustion is suspected:
   ```bash
   sudo systemctl restart fake-service
   ```
4. If the issue is limited to a specific endpoint, rate-limit or disable it temporarily while a fix is deployed
