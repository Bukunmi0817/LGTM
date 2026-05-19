# CPU Alerts

Covers: `CPUWarning`, `CPUCritical`

---

### CPUWarning

| Field | Value |
|---|---|
| Severity | warning |
| Threshold | CPU > 80% averaged over 5 minutes |
| Fire duration | 5 minutes |

**What it means**
CPU utilisation has been above 80% for at least 5 minutes on one instance. This is not yet critical but is a leading indicator. Left unattended it typically escalates to `CPUCritical` and can degrade request latency as the scheduler queues work.

**Diagnose**

SSH to the affected instance (check `$labels.instance` in the alert) and run:

```bash
# See the top CPU consumers right now
top -b -n1 | head -20

# Or in a more readable format
ps aux --sort=-%cpu | head -15

# Check if it started after a recent deploy
journalctl -u fake-service --since "30 minutes ago" | tail -40
```

Also open the Node Exporter dashboard and inspect the CPU panel — look for whether a single core is saturated (possible single-threaded bottleneck) or all cores are elevated (overall load).

**Resolve**

- If a single runaway process: `sudo kill -9 <pid>` or `sudo systemctl restart <service>`
- If it correlates with a recent deployment: consider rolling back
- If sustained high load with no runaway process: the instance may be undersized — check whether `fake-service` memory or concurrency settings need tuning
- Monitor for 10 minutes after action to confirm the alert resolves

**Escalate if** the alert persists for 30+ minutes or if CPU climbs toward 90% (which will trigger `CPUCritical`).

---

### CPUCritical

| Field | Value |
|---|---|
| Severity | critical |
| Threshold | CPU > 90% averaged over 5 minutes |
| Fire duration | 10 minutes |

**What it means**
Ten consecutive minutes above 90% CPU. At this point the scheduler is heavily contending and request latency will be noticeably elevated. Processes may start timing out. This is not a transient spike.

**Diagnose**

```bash
# Identify the dominant process
ps aux --sort=-%cpu | head -10

# Check for OOM pressure (swap tells you memory is spilling over, adding CPU overhead)
free -h
vmstat 1 5

# Check service logs for errors indicating a feedback loop (e.g. retry storms)
journalctl -u fake-service -n 100 --no-pager | grep -i "error\|retry\|timeout"
```

**Resolve**

1. Kill or restart the dominant process immediately:
   ```bash
   sudo systemctl restart fake-service
   ```
2. If the issue recurs after restart, a recent code change is likely responsible — rollback:
   ```bash
   git revert HEAD && git push
   ```
3. If the instance itself is genuinely undersized, update `var.app_instance_type` in Terraform and apply.

**Escalate if** the instance becomes unresponsive over SSH or if the alert does not resolve within 15 minutes of restarting the service.
