# Memory Alerts

Covers: `MemoryWarning`, `MemoryCritical`

---

### MemoryWarning

| Field | Value |
|---|---|
| Severity | warning |
| Threshold | Memory used > 80% for 5 minutes |
| Fire duration | 5 minutes |

**What it means**
Less than 20% of physical RAM is available. The system is not yet swapping but will begin to under continued growth. Memory warnings on the app server typically indicate a leak in `fake-service`; on the monitoring server they indicate Prometheus TSDB or Loki chunk cache growth.

**Diagnose**

```bash
# Total picture
free -h

# Top consumers
ps aux --sort=-%mem | head -10

# For Loki/Prometheus memory growth on monitoring server
systemctl status loki prometheus
journalctl -u loki -n 50 --no-pager | grep -i "mem\|oom\|warn"
```

**Resolve**

- If `fake-service` is the top consumer and it has been running for days without restart, it is likely leaking:
  ```bash
  sudo systemctl restart fake-service
  ```
- If Prometheus TSDB is growing, check the retention period in `prometheus.yml` and whether the volume has adequate free space.
- If Loki is the consumer, check ingestion rate vs. the `ingestion_rate_mb` limit in `loki-config.yml`.

**Escalate if** memory climbs past 90% (which will fire `MemoryCritical`) or if swapping starts (`vmstat` shows non-zero `si`/`so` columns).

---

### MemoryCritical

| Field | Value |
|---|---|
| Severity | critical |
| Threshold | Memory used > 90% for 5 minutes |
| Fire duration | 5 minutes |

**What it means**
The OOM killer may fire at any moment. Services can be killed without warning. This requires immediate intervention.

**Diagnose**

```bash
free -h
ps aux --sort=-%mem | head -10

# Check if OOM killer has already fired
sudo dmesg | grep -i "oom\|killed process" | tail -10
journalctl -k | grep -i oom | tail -10
```

**Resolve**

1. Immediately free memory by restarting the top consumer:
   ```bash
   sudo systemctl restart <top-consumer-service>
   ```
2. If the OOM killer has already fired, check which service was killed and restart it:
   ```bash
   sudo dmesg | grep "Killed process"
   sudo systemctl restart <killed-service>
   ```
3. Drop OS page cache if legitimate application memory is fine (use with care):
   ```bash
   sudo sync && sudo sh -c 'echo 3 > /proc/sys/vm/drop_caches'
   ```
4. If the root cause is genuine load growth, increase the instance type in Terraform.

**Escalate if** the OOM killer fires repeatedly or if a core service (Loki, Prometheus, Grafana) is being killed.
