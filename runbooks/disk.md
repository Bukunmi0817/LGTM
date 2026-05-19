# Disk Alerts

Covers: `DiskWarning`, `DiskCritical`

---

### DiskWarning

| Field | Value |
|---|---|
| Severity | warning |
| Threshold | Disk used > 75% on any non-tmpfs mount |
| Fire duration | 5 minutes |

**What it means**
A filesystem is three-quarters full. The monitoring server's root volume fills primarily from Prometheus TSDB blocks and Loki chunks. At 75% there is still time to act before service disruption.

**Diagnose**

```bash
# Which filesystem is it? (check $labels.mountpoint in the alert)
df -h

# Where is the space going?
sudo du -sh /var/lib/lgtm/*
sudo du -sh /var/log/*

# Check Prometheus TSDB retention is working
ls -lh /var/lib/lgtm/prometheus/
```

**Resolve**

- Clean old journal logs:
  ```bash
  sudo journalctl --vacuum-time=7d
  ```
- If Prometheus TSDB blocks are accumulating, confirm the retention setting is active:
  ```bash
  curl -s http://localhost:9090/api/v1/status/flags | grep retention
  ```
- If Loki chunks are the culprit, check the compactor is running and retention is enabled in `loki-config.yml` (`retention_enabled: true`).
- If legitimate data growth is the cause, expand the EBS volume in Terraform (`volume_size` in the `root_block_device` block) and grow the filesystem:
  ```bash
  sudo growpart /dev/nvme0n1 1
  sudo resize2fs /dev/nvme0n1p1
  ```

**Escalate if** disk grows past 90% before the cleanup completes (which will fire `DiskCritical`).

---

### DiskCritical

| Field | Value |
|---|---|
| Severity | critical |
| Threshold | Disk used > 90% on any non-tmpfs mount |
| Fire duration | 5 minutes |

**What it means**
Disk is nearly full. Prometheus will stop ingesting metrics, Loki will fail to write chunks, and the OS itself may fail to write to `/tmp` or `/var`. Services will begin crashing within minutes once the filesystem hits 100%.

**Diagnose**

```bash
df -h
sudo du -sh /var/lib/lgtm/* | sort -rh | head -10
sudo du -sh /var/log/* | sort -rh | head -5
```

**Resolve — act in this order:**

1. Immediately free space from logs:
   ```bash
   sudo journalctl --vacuum-size=200M
   sudo find /var/log -name "*.gz" -delete
   sudo find /var/log -name "*.1" -delete
   ```
2. Remove old Prometheus TSDB blocks if they are the dominant consumer:
   ```bash
   # Only remove blocks older than the retention period
   ls -lt /var/lib/lgtm/prometheus/
   ```
3. If still critical, expand the EBS volume immediately (this is the safest long-term action):
   - Update `volume_size` in `terraform/main.tf` and run `terraform apply`
   - Then grow the partition in-place:
     ```bash
     sudo growpart /dev/nvme0n1 1
     sudo resize2fs /dev/nvme0n1p1
     ```

**Escalate if** you cannot free enough space within 10 minutes. At that point the monitoring stack itself is at risk of total failure.
