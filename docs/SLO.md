# Service Level Objectives — Cloud Lab API

**Service:** Cloud Lab API (`cloud-lab`)
**Owner:** Platform / SRE
**Review cadence:** Monthly
**Last reviewed:** 2025-05

---

## Why this document exists

SLOs translate reliability into a shared contract between engineering and stakeholders. They define what "good enough" looks like, make error budgets calculable, and give the team a principled basis for deciding when to prioritise reliability work over feature delivery.

---

## Service description

Cloud Lab API is a FastAPI application that simulates a production microservice. It exposes an HTTP API and a Prometheus `/metrics` endpoint. It is used as the instrumented target for the Cloud Lab SRE portfolio environment.

---

## SLIs — what we measure

| SLI | Metric | Description |
|---|---|---|
| Availability | `http_requests_total{status}` | Ratio of successful requests to total requests |
| Latency | `http_request_duration_seconds` | Request processing time measured at the server |
| Error rate | `http_requests_total{status="error"}` | Proportion of requests returning an error |

A request is counted as **successful** if it completes without raising an exception and returns HTTP 200. A request is counted as **failed** if it raises an unhandled exception (HTTP 500) or the service is unreachable.

---

## SLOs — our commitments

### SLO 1 — Availability

| Property | Value |
|---|---|
| Target | **99.0%** of requests succeed over a rolling 30-day window |
| Error budget | 1.0% of requests may fail (≈ 7h 18m of downtime equivalent per month) |
| Measurement window | 30 days rolling |
| Alert: warning | Error rate > 5% for 1 minute |
| Alert: critical | Error rate > 10% for 2 minutes |

**PromQL:**
```promql
rate(http_requests_total{status="success"}[5m])
/
rate(http_requests_total[5m])
```

---

### SLO 2 — Latency

| Property | Value |
|---|---|
| Target | **95%** of requests complete in under **500ms** |
| Stretch target | 99% of requests complete in under **1000ms** |
| Measurement window | 5-minute rolling window |
| Alert: warning | p95 > 500ms for 1 minute |
| Alert: critical | p95 > 1000ms for 2 minutes |

**PromQL:**
```promql
histogram_quantile(0.95, rate(http_request_duration_seconds_bucket[5m])) < 0.5
```

---

## Error budget

The error budget is the maximum amount of unreliability the service is permitted to have while still meeting its SLO.

| Window | Allowed failures (Availability SLO) |
|---|---|
| Daily | 1.0% of daily requests |
| Weekly | 1.0% of weekly requests |
| Monthly | 1.0% of monthly requests (~7h 18m equivalent |

### Burn rate interpretation

Burn rate measures how fast the error budget is being consumed relative to sustainable pace.

| Burn rate | Meaning | Action |
|---|---|---|
| < 1x | Under budget — reliability headroom exists | Normal operations |
| 1–6x | Elevated — monitor closely | Review recent changes |
| 6–14.4x | High — budget at risk | Incident response |
| > 14.4x | Critical — budget exhausted in < 2h | Page on-call immediately |

---

## What happens when the error budget is exhausted

When the error budget is fully consumed before the end of the monthly window:

1. Feature releases are paused until the budget recovers
2. Engineering focus shifts to reliability improvements
3. A postmortem is required for the contributing incident(s)
4. SLO targets are reviewed if budget is consistently exhausted

---

## SLO review process

SLOs should be reviewed monthly. Questions to answer at each review:

- Was the SLO met this period?
- Was the error budget meaningfully consumed? By what?
- Is the target too tight (causing constant alerting) or too loose (hiding real problems)?
- Do the SLIs still reflect what users actually care about?

---

## Out of scope

The following are not currently covered by these SLOs and would be added as the service matures:

- Throughput / request volume SLOs
- Data correctness / integrity SLOs
- Dependency availability (database, external APIs)
- Regional availability breakdown
