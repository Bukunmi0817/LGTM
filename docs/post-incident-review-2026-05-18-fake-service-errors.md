# Blameless Post-Incident Review

## Incident Title

Elevated 5xx Error Rate on `fake-service` Checkout Traffic

## Incident Date

May 18, 2026

## Summary

On May 18, 2026, the `fake-service` experienced a sustained spike in 5xx
responses on the `/api/checkout` path. The service remained reachable and the
`/health` endpoint continued to return `200`, so the incident primarily
manifested as an application reliability failure rather than an availability
outage.

The issue was detected through the Reliability dashboards in Grafana after the
Golden Signals error-rate panel rose sharply and the HTTP Errors dashboard
showed concentrated failures on a single endpoint. The team used correlated
logs and traces in the Unified Observability dashboard to confirm that the
failing requests shared the same request pattern and trace shape. Traffic was
stabilized by stopping the error-inducing behavior on the app server and
returning the service to its normal background traffic pattern.

This review is blameless. The incident was the result of system gaps in alert
coverage, scenario safety controls, and end-to-end validation, not individual
mistakes.

## Impact

- Affected service: `fake-service`
- Affected endpoint: `/api/checkout`
- User impact: a meaningful percentage of simulated checkout requests returned
  `500` responses during the incident window
- Availability impact: low, because `/health` remained reachable and Blackbox
  probing stayed green
- Reliability impact: high, because request success rate degraded sharply on a
  user-facing path

## Severity

SEV-2

Rationale:
- The service stayed up.
- Core request quality degraded on a critical application path.
- The incident required operator intervention and rollback-to-normal behavior.

## Detection

Primary signals:
- `Reliability -> Golden Signals` showed an elevated error-rate percentage
- `Reliability -> HTTP Errors` showed `/api/checkout` as the dominant 5xx
  source
- `Observability -> Unified` showed correlated `ERROR` logs with trace IDs
- Tempo traces confirmed repeated failing request spans for the same route

Detection gaps:
- The current alerting model is stronger for availability than for
  application-level 5xx spikes.
- Because `/health` stayed healthy, the Blackbox-based availability alerts did
  not fire even though request quality was degraded.

## Timeline

All times below are in WAT on May 18, 2026.

| Time | Event |
|---|---|
| 14:02 | Elevated 5xx responses begin on `/api/checkout` |
| 14:05 | Golden Signals error-rate panel rises above normal baseline |
| 14:07 | HTTP Errors dashboard confirms `/api/checkout` as primary failing route |
| 14:10 | On-call engineer opens Unified Observability and reviews correlated logs |
| 14:13 | Trace inspection in Tempo confirms repeated failing request spans tied to checkout traffic |
| 14:18 | Team determines this is request-quality degradation, not full service downtime |
| 14:24 | Operators stop the error-inducing behavior on the app server and restore normal traffic pattern |
| 14:31 | Error-rate panel begins to recover, but Prometheus rate windows remain elevated |
| 14:42 | Dashboards return near baseline and no fresh error burst is visible |
| 14:54 | Incident declared resolved after sustained stabilization |

## Root Cause

`fake-service` generated a concentrated burst of failing checkout requests,
producing a sustained 5xx spike on `/api/checkout`. The failure mode was
application-level rather than infrastructure-level: the service process stayed
up, Prometheus scraping continued, traces were exported, and `/health`
remained healthy.

In practical terms, the system could still answer "Are you alive?" while
failing to answer "Can you serve an important request successfully?"

## Contributing Factors

### 1. Availability and request quality are monitored differently

The current architecture measures availability through Blackbox probing of
`/health`, while request failures are measured through application metrics from
`http_requests_total`. This is valid, but it means application degradation can
be severe without tripping the availability alert path.

### 2. Alert coverage is incomplete for this failure mode

The stack has strong availability and latency SLO alerts, but request-error
alerting for concentrated 5xx bursts is weaker than it should be for game-day
and operational use.

### 3. The game-day paths are not equally deterministic

The repository contains chaos flows for error and latency scenarios, but not
all of them map cleanly to the formal SLO alerts. This increases operator
uncertainty during validation and slows confident incident classification.

### 4. Trace-to-logs is implemented but not fully validated end to end

The incident investigation benefited from logs and traces being present, but
the repo does not yet include an automated verification that a real log entry
in Loki can be clicked through consistently into the matching trace in Tempo.

## What Went Well

- Golden Signals made the degradation visible quickly.
- HTTP Errors narrowed the problem to a single route without guesswork.
- Unified Observability reduced context switching across metrics, logs, and
  traces.
- The system remained instrumented during the incident, so diagnosis did not
  depend on SSH-first debugging.
- Recovery was fast once the issue was classified as request-quality
  degradation rather than a full outage.

## What Went Poorly

- The incident did not align cleanly with the strongest existing alert path.
- The service could fail user-facing requests while still appearing healthy to
  the Blackbox availability probe.
- The current runbooks rely too heavily on operator interpretation for
  distinguishing "service up" from "service working."
- End-to-end validation of trace-to-logs and logs-to-traces is still manual.

## Resolution

The team resolved the incident by removing the error-inducing traffic pattern
on the app server and allowing the service to return to its steady-state
background simulator behavior. Metrics normalized first on raw counters and
then on dashboard rate windows after a short decay period.

No infrastructure restart was required. No data-plane dependency outside the
app server or monitoring server had to be replaced.

## Customer Communication

Because this is an internal observability demo stack, external customer
communication was not required. Internally, the team documented the timeline,
captured the impacted route, and recorded follow-up work to close alerting and
validation gaps.

## Lessons Learned

### 1. Health checks are necessary but not sufficient

A healthy `/health` endpoint does not prove that important request paths are
working correctly. We need clear separation between uptime, request success,
and latency in both dashboards and alerting.

### 2. Game-day scenarios must map cleanly to alert intent

If a scenario is meant to exercise an alert, it must actually degrade the SLI
that the alert evaluates. Otherwise the exercise tests operator confusion more
than system behavior.

### 3. Cross-signal investigation is a real strength of this stack

The combination of Golden Signals, HTTP Errors, logs, and traces gave the team
an efficient investigation path. This is worth preserving and validating more
rigorously.

## Follow-Up Actions

| Priority | Action | Owner | Due Date |
|---|---|---|---|
| P1 | Add an application 5xx burn/error alert that matches the current `error-burst` failure mode | Observability | May 26, 2026 |
| P1 | Add a deterministic latency-injection path so latency game days map directly to the latency SLO | App Platform | May 27, 2026 |
| P1 | Add an explicit "request quality degraded, service still up" runbook | SRE | May 28, 2026 |
| P2 | Add an end-to-end validation check for log-to-trace and trace-to-log correlation | Observability | May 31, 2026 |
| P2 | Review whether `/health` should include deeper dependency checks or remain intentionally shallow | Platform | June 2, 2026 |
| P3 | Add a PIR template to the repo for future incidents and game-day exercises | SRE Enablement | June 5, 2026 |

## Preventive Changes Recommended

- Keep the Blackbox availability SLO as-is, but add request-failure alerting
  that is independent of `/health`.
- Make each chaos scenario deterministic and explicitly mapped to one expected
  dashboard pattern and one expected alert path.
- Add lightweight automated validation for observability links, especially the
  log-to-trace flow used during investigation.

## Closing Statement

This incident did not happen because someone acted carelessly. It happened
because the system allowed a meaningful gap between uptime signals, request
quality signals, and alert coverage. The right response is to improve the
system so future operators have clearer signals, safer drills, and faster
recovery paths.
