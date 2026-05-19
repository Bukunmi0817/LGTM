# Reliability Documentation

This document defines the service-level indicators (SLIs), service-level objectives (SLOs), error budget calculations, and error budget policy for the LGTM demo service.

Scope:
- Service: `fake-service`
- Signals source: Prometheus metrics emitted by `fake-service` and Blackbox Exporter
- Evaluation window for SLOs: rolling 30 days

## Four Golden Signals SLI Definitions

The four golden signals are the first-line view of service health. They are used for operational triage even when only two of them currently have formal error-budget-backed SLOs.

| Signal | SLI definition | PromQL | Notes |
|---|---|---|---|
| Traffic | Total request rate across all endpoints | `sum(rate(http_requests_total[1m]))` | Use `sum by(endpoint) (rate(http_requests_total[1m]))` to break traffic down by route. |
| Errors | Percentage of requests returning 5xx | `sum(rate(http_requests_total{status_code=~"5.."}[5m])) / sum(rate(http_requests_total[5m])) * 100` | This is the main request-failure SLI for application errors. |
| Latency | p95 request latency | `histogram_quantile(0.95, sum by(le) (rate(http_request_duration_seconds_bucket[5m])))` | Used for operational latency monitoring. |
| Latency compliance | Percentage of requests completed in <= 500ms | `sum(rate(http_request_duration_seconds_bucket{le="0.5"}[5m])) / sum(rate(http_request_duration_seconds_count[5m])) * 100` | This is the latency SLI used for the formal latency SLO. |
| Saturation | CPU utilization | `avg_over_time(process_cpu_usage_percent[5m])` | Saturation is modeled as a bundle rather than a single metric. |
| Saturation | Memory utilization | `avg_over_time(process_memory_usage_percent[5m])` | Review alongside CPU so a single hot resource does not get hidden. |
| Saturation | Active connections | `avg_over_time(http_active_connections[5m])` | Useful as a load-pressure indicator and to explain rising CPU or latency. |

### Why Saturation Has Multiple Indicators

Traffic, errors, and latency each have a natural primary SLI. Saturation does not. For this service, saturation is intentionally represented by CPU, memory, and active connections together because each captures a different failure mode:

- CPU shows compute pressure.
- Memory shows working-set pressure and leak-style behavior.
- Active connections show queueing and concurrency pressure.

## SLO Targets

The service currently has two formal customer-facing SLOs with explicit error budgets: availability and latency.

### 1. Availability SLO

Target:
- 99.5% successful Blackbox probes to `/health` over a rolling 30-day window

SLI:

```promql
avg_over_time(probe_success{job="blackbox-http"}[30d]) * 100
```

Rationale:
- This stack is a single-region, two-instance demo platform on EC2, not a multi-AZ or fully redundant production service.
- A 99.9% target would allow only 43.2 minutes of downtime per 30 days and would be stricter than the current architecture justifies.
- A 99.5% target still forces meaningful operational discipline while leaving room for planned iteration, infrastructure churn, and controlled chaos testing.

Error budget calculation:
- Allowed failure fraction: `1 - 0.995 = 0.005`
- 30 days = `30 * 24 = 720` hours
- Error budget in hours: `720 * 0.005 = 3.6` hours
- Error budget in minutes: `3.6 * 60 = 216` minutes

Result:
- Availability error budget = 3.6 hours per rolling 30 days

Budget remaining formula:

```promql
((avg_over_time(probe_success{job="blackbox-http"}[30d]) - 0.995) / 0.005) * 100
```

Budget consumed formula:

```promql
(1 - avg_over_time(probe_success{job="blackbox-http"}[30d])) / 0.005 * 100
```

### 2. Latency SLO

Target:
- 95% of requests complete in <= 500ms over a rolling 30-day window

SLI:

```promql
sum(increase(http_request_duration_seconds_bucket{le="0.5"}[30d]))
/
sum(increase(http_request_duration_seconds_count[30d]))
* 100
```

Rationale:
- The service is explicitly designed to simulate realistic latency variation and occasional spikes for observability and incident response exercises.
- The user-facing threshold should still be tight enough to reveal regressions early.
- A 500ms threshold at 95% captures meaningful degradation without forcing the demo workload into unrealistic low-latency constraints.

Error budget calculation:
- Allowed slow-request fraction: `1 - 0.95 = 0.05`
- Error budget is request-based, not time-based.
- This means up to 5% of requests in the rolling 30-day window may exceed 500ms before the SLO is violated.

Examples:
- If the service serves 100,000 requests in 30 days, up to 5,000 may exceed 500ms.
- If the service serves 1,000,000 requests in 30 days, up to 50,000 may exceed 500ms.

Result:
- Latency error budget = 5% of request volume per rolling 30 days

Budget remaining formula:

```promql
(
  1 - (
    (
      1 - (
        sum(increase(http_request_duration_seconds_bucket{le="0.5"}[30d]))
        /
        sum(increase(http_request_duration_seconds_count[30d]))
      )
    ) / 0.05
  )
) * 100
```

Budget consumed formula:

```promql
(
  1 - (
    sum(increase(http_request_duration_seconds_bucket{le="0.5"}[30d]))
    /
    sum(increase(http_request_duration_seconds_count[30d]))
  )
) / 0.05 * 100
```

## Burn Rate Alert Thresholds

The burn-rate thresholds follow the standard multiwindow pattern already used by the stack:

- Fast burn: 14.4x budget consumption, alert after 2 minutes
- Slow burn: 5x budget consumption, alert after 15 minutes

### Availability burn rate

Fast burn:

```promql
(
  1 - (
    sum(rate(probe_success{job="blackbox-http"}[1h]))
    /
    count(probe_success{job="blackbox-http"})
  )
) > (14.4 * 0.005)
```

Slow burn:

```promql
(
  1 - (
    sum(rate(probe_success{job="blackbox-http"}[6h]))
    /
    count(probe_success{job="blackbox-http"})
  )
) > (5 * 0.005)
```

Interpretation:
- `14.4 * 0.005 = 0.072`, so fast burn means more than 7.2% unavailability in the alert window.
- `5 * 0.005 = 0.025`, so slow burn means more than 2.5% unavailability in the alert window.

### Latency burn rate

Fast burn:

```promql
(
  1 - (
    sum(rate(http_request_duration_seconds_bucket{le="0.5"}[1h]))
    /
    sum(rate(http_request_duration_seconds_count[1h]))
  )
) > (14.4 * 0.05)
```

Slow burn:

```promql
(
  1 - (
    sum(rate(http_request_duration_seconds_bucket{le="0.5"}[6h]))
    /
    sum(rate(http_request_duration_seconds_count[6h]))
  )
) > (5 * 0.05)
```

Interpretation:
- `14.4 * 0.05 = 0.72`, so fast burn means more than 72% of requests are slower than 500ms in the alert window.
- `5 * 0.05 = 0.25`, so slow burn means more than 25% of requests are slower than 500ms in the alert window.

## Error Budget Policy

### Purpose

The error budget is the decision mechanism that balances feature delivery against reliability work. If the service is comfortably inside budget, the team can continue shipping. If the service is burning or has exhausted budget, reliability work takes priority over new feature work.

### Policy States

| Budget remaining | State | Delivery policy |
|---|---|---|
| > 50% | Healthy | Normal feature delivery. Reliability work continues as planned. |
| 25% to 50% | Caution | Review recent changes before release. Increase dashboard and alert review frequency. |
| 10% to 25% | At risk | Limit non-essential changes. Prioritize reliability fixes and observability gaps. |
| 0% to 10% | Critical | Freeze feature work on the affected service. Only fixes, mitigations, and rollback-safe changes allowed. |
| <= 0% | Exhausted | No new feature releases for the affected service until budget recovers or leadership explicitly approves an exception. |

### Response Rules

When a fast-burn alert fires:
- Treat it as an active incident.
- Open Golden Signals first, then HTTP Errors, then Unified Observability.
- If a recent deployment correlates with the regression, prefer rollback over extended live debugging.
- Document the incident timeline and record MTTR after recovery.

When a slow-burn alert fires:
- Treat it as a reliability regression even if customers are not yet reporting an outage.
- Review changes from the last 24 hours.
- Decide whether the regression can be fixed safely in-place or should be rolled back.
- Create follow-up work if the root cause is architectural rather than release-specific.

When budget reaches the At risk state:
- Reliability work becomes the default priority for the service.
- New changes should be small, reversible, and directly justified.

When budget is exhausted:
- Stop feature work for the affected service.
- Allow only rollback, incident mitigation, observability fixes, and reliability improvements.
- A post-incident review is required before normal delivery resumes.

### Exceptions

The following do not count against error budget if they are announced and documented:
- Planned maintenance with alerts suppressed in advance
- Approved chaos exercises using `fake-service/chaos.sh`
- Third-party or cloud-provider incidents outside the service team's reasonable control

### Review Cadence

- Review SLO attainment weekly.
- Review error budget consumption after every incident.
- Revisit targets when architecture changes materially, especially if the service moves from single-instance style deployment to a more redundant topology.
