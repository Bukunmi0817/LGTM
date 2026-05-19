# Server Availability Alerts

Covers: `ServerDown`, `ServerRecovered`

---

### ServerDown

| Field | Value |
|---|---|
| Severity | critical |
| Threshold | Blackbox probe returning `probe_success == 0` |
| Fire duration | 2 minutes |

**What it means**
The Blackbox Exporter's HTTP probe has been failing for 2+ minutes against a monitored endpoint. The service is either down, unreachable over the network, or returning non-2xx responses. Check `$labels.instance` to identify which endpoint is failing.

**Diagnose**

```bash
# From the monitoring server, manually replay the probe
curl -sv http://<instance>/health
curl -sv http://<instance>:8080/health

# If the fake service, check on the app server
sudo systemctl status fake-service
sudo journalctl -u fake-service -n 50 --no-pager

# Check basic node reachability
ping <instance-ip>
nc -zv <instance-ip> 8080
```

Also check the Blackbox Exporter dashboard in Grafana — it shows probe duration and status code history, which reveals whether this is a total outage or intermittent flapping.

**Resolve**

- If the service process is dead:
  ```bash
  sudo systemctl restart fake-service
  ```
- If the instance itself is unreachable (ping fails), log in via AWS EC2 Connect in the console or reboot the instance from there.
- If the probe target URL is wrong, update `configs/prometheus/prometheus.yml` and reload Prometheus:
  ```bash
  curl -X POST http://localhost:9090/-/reload
  ```

**Escalate if** the instance is not reachable via SSH and the AWS console shows it in a stopped or failed state.

---

### ServerRecovered

| Field | Value |
|---|---|
| Severity | info |
| Threshold | `probe_success == 1` for 1 minute after a `ServerDown` event |
| Fire duration | 1 minute |

**What it means**
Informational only. The previously failing probe is succeeding again. No action required beyond confirming resolution and recording MTTR if the outage was significant.

**Action**

1. Confirm the corresponding `ServerDown` alert has resolved in Alertmanager
2. Verify service health looks stable on the Blackbox dashboard (no flapping)
3. If the outage lasted more than a few minutes, push the MTTR to Pushgateway:
   ```bash
   OUTAGE_DURATION_SECONDS=<seconds-from-alert-fire-to-recovery>
   curl -X POST http://<monitoring-ip>:9091/metrics/job/incident-mttr \
     --data-binary "incident_mttr_seconds ${OUTAGE_DURATION_SECONDS}"
   ```
