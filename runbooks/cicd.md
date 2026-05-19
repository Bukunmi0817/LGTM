# CI/CD Alerts

Covers: `DeploymentFailed`, `HighChangeFailureRate`, `MTTRExceeded`

---

### DeploymentFailed

| Field | Value |
|---|---|
| Severity | critical |
| Threshold | `github_last_deploy_status == 1` (most recent deploy on any branch failed) |
| Fire duration | Immediate (0m) |

**What it means**
The most recent GitHub Actions deployment run on a tracked branch failed. The CFR metric is now incrementing. Unresolved deployment failures compound the 30-day CFR calculation and will eventually trigger `HighChangeFailureRate`.

Check `$labels.branch` and `$labels.workflow` in the alert to identify which branch and pipeline failed.

**Diagnose**

1. Go to the GitHub Actions tab for this repository
2. Find the failed run on the branch named in the alert
3. Expand the failing step — common failure modes:

| Failing step | Likely cause |
|---|---|
| `Validate Prometheus config` | Syntax error in `prometheus.yml` or a rules file |
| `Validate YAML configs` | `yamllint` found formatting issues in `configs/` |
| `Push DORA metrics` | Pushgateway unreachable on port 9091 |

```bash
# Reproduce validation failures locally
promtool check config configs/prometheus/prometheus.yml
promtool check rules configs/prometheus/rules/infrastructure.yml
promtool check rules configs/prometheus/rules/slo_burn_rate.yml
promtool check rules configs/prometheus/rules/cicd.yml
yamllint -c .yamllint configs/

# If the failure was a DORA push, check Pushgateway on the monitoring server
sudo systemctl status pushgateway
curl -s http://localhost:9091/metrics | head -5
```

**Resolve**

- Fix the root cause in the code/config, commit, and push to trigger a new run
- Once a successful run completes, `github_last_deploy_status` is overwritten to 0 and the alert resolves automatically
- Do not merge additional changes to the failing branch until the pipeline is green

**Note:** This alert resolves on the next successful deploy, not on a timer. A failed deploy that is never fixed will keep this alert firing indefinitely.

---

### HighChangeFailureRate

| Field | Value |
|---|---|
| Severity | critical |
| Threshold | Rolling 30-day CFR > 15% |
| Fire duration | 5 minutes |

**What it means**
More than 15% of deployments in the last 30 days have failed. This is the DORA Change Failure Rate SLO threshold. A high CFR indicates a systemic problem in the release process: insufficient testing, fragile infrastructure, or deployments that are too large to validate safely.

**Diagnose**

Open the **DORA Metrics** dashboard in Grafana. The CFR panel shows the rolling rate. Identify:
- When did the rate cross 15%?
- Which branches are contributing most failures?
- Is there a pattern — specific type of change, specific day/time?

```bash
# Inspect raw failure records from Pushgateway
curl -s http://localhost:9091/metrics | grep 'github_deploy_timestamp_seconds.*status="failure"'
```

**Resolve**

This alert reflects a process problem, not a single incident. Remediation is longer-term:

1. **Immediate**: Fix any currently-failing pipelines (see `DeploymentFailed` runbook)
2. **Short-term**: Identify the most common failure type:
   - Validation failures → add local pre-commit hooks (`promtool`, `yamllint`) to catch them before push
   - Infrastructure failures → add health checks and better error handling to deploy scripts
   - Rollbacks from bad deploys → improve feature flagging so incomplete features don't reach production
3. **Long-term**: Consider a reliability sprint focused on improving pipeline stability and test coverage

The alert will naturally resolve as successful deploys accumulate and the 30-day window rolls forward past the failure cluster.

---

### MTTRExceeded

| Field | Value |
|---|---|
| Severity | warning |
| Threshold | `incident_mttr_seconds > 14400` (4 hours) |
| Fire duration | Immediate (0m) |

**What it means**
The last recorded incident took more than 4 hours to resolve, exceeding the MTTR SLO target. This metric is pushed manually to Pushgateway after an incident closes — it does not fire during an active incident, only after.

**Pushing the MTTR metric**

After resolving an incident, push the duration:
```bash
MTTR_SECONDS=<seconds-from-incident-start-to-resolution>
curl -X POST http://<monitoring-ip>:9091/metrics/job/incident-mttr \
  --data-binary "incident_mttr_seconds ${MTTR_SECONDS}"
```

**Diagnose**

Review the incident timeline to understand where time was lost:

| Phase | Question |
|---|---|
| Detection | How long between the failure starting and the alert firing? |
| Diagnosis | How long to identify the root cause after the alert fired? |
| Resolution | How long to implement and verify the fix? |

Common causes of MTTR > 4 hours:
- No runbook existed for the alert type — the responder had to investigate from scratch
- Insufficient logging or tracing made the root cause hard to find
- The fix required a new deployment which had its own pipeline delay
- Escalation was delayed because on-call contacts were unclear

**Resolve**

This alert is a post-incident signal, not an ongoing problem. Resolution is through process improvement:

1. Conduct a postmortem and identify which phase consumed the most time
2. Update the relevant runbook section with what you learned
3. If detection was slow: review alert thresholds and `for` durations
4. If diagnosis was slow: improve logging in `fake-service`, confirm traces are flowing to Tempo
5. If resolution was slow: consider whether the deployment pipeline can be accelerated for hotfixes

After completing the postmortem, clear the metric so the alert resolves:
```bash
curl -X DELETE http://<monitoring-ip>:9091/metrics/job/incident-mttr
```
