# Tool Guide

Plain-English reference for every tool in the lab — what it does, how to use
it, how to test it, and what a healthy result looks like.

---

## sre-lab.sh — Master control script

**What it is:** Single script that replaces `lab`, `startup.sh`, and
`shutdown.sh`. Controls the entire lab lifecycle.

**How to use:**

```bash
./sre-lab.sh start      # start everything
./sre-lab.sh stop       # stop everything
./sre-lab.sh status     # check everything is healthy
./sre-lab.sh open       # show all URLs
```

**How to test:**

```bash
./sre-lab.sh start
./sre-lab.sh status
```

**Healthy result:**
```
✓ App liveness
✓ App readiness
✓ App circuit breaker
✓ App metrics
✓ Prometheus
✓ Grafana
✓ Alertmanager
✓ Jaeger
```

All 8 checks green. Any ⚠ means a pod is still starting — wait 30 seconds
and run status again.

---

## generate-traffic.sh — Traffic simulation

**What it is:** Sends HTTP requests to the app in different patterns to
populate metrics and trigger alerts.

**How to use:**

```bash
./generate-traffic.sh mixed        # 3 minutes of randomised traffic (default)
./generate-traffic.sh normal       # steady baseline — 10 req/10s for 2 mins
./generate-traffic.sh spike        # sudden burst of 100 concurrent requests
./generate-traffic.sh error-flood  # hits bad endpoints to drive up error rate
./generate-traffic.sh slow-burn    # sustained load for 5 minutes
./generate-traffic.sh slo-breach   # designed to trigger SLO alerts
```

**How to test:**

```bash
# Run in background, check metrics are populating
./generate-traffic.sh mixed &
sleep 30

# Query Prometheus — should return ~0.70
curl -s "http://localhost:9090/api/v1/query?query=slo:success_rate_5m" | \
  python3 -m json.tool | grep value
```

**Healthy result:** `slo:success_rate_5m` returns approximately `0.70`
(70% success — your app's 30% error rate in action).

**Note:** The app runs on `http://localhost:8888`. If the script shows
`OK: 0 | Fail: all` the port-forward has dropped — run `./sre-lab.sh start`.

---

## Prometheus — Metrics collection

**What it is:** Scrapes `/metrics` from your app pods every 5 seconds and
stores time-series data. Evaluates alert rules every 15 seconds.

**URL:** `http://localhost:9090`

**How to use:**

| Task | URL |
|---|---|
| Query metrics | http://localhost:9090 → Graph tab |
| Check targets are up | http://localhost:9090/targets |
| Check alerts | http://localhost:9090/alerts |

**Key queries to run:**

```promql
# Is the app being scraped?
up{job="cloud-lab-app"}

# Current success rate (should be ~0.70 with traffic running)
slo:success_rate_5m

# p95 latency (should be ~0.2s at rest)
slo:latency_p95_5m

# Error budget burn rate (will be high due to 30% error rate)
slo:error_budget_burn_rate_1h

# Circuit breaker state
circuit_breaker_state
```

**How to test:**

1. Go to `http://localhost:9090/targets`
2. Confirm `cloud-lab-app` shows **State: UP** for both pods
3. Run `./generate-traffic.sh mixed` for 1 minute
4. Query `slo:success_rate_5m` — should return a value, not NaN

**Healthy result:** Two targets showing UP in green, recording rules
returning real values after traffic flows.

---

## Grafana — Dashboards

**What it is:** Visualises Prometheus metrics as charts and gauges.
Your SRE Overview dashboard has 9 panels.

**URL:** `http://localhost:3000` (admin/admin)

**How to use:**

1. Login with admin/admin
2. Go to Dashboards → Cloud Lab → SRE Overview
3. Set time range to "Last 15 minutes"
4. Run traffic: `./generate-traffic.sh mixed &`

**Dashboard panels:**

| Panel | What it shows | Healthy value |
|---|---|---|
| Availability (5m) | % of requests succeeding | ~70% (30% error rate is intentional) |
| Error Budget Remaining | Budget left this month | Will show negative — correct for lab |
| Burn Rate (1h) | How fast budget is consumed | High number — expected |
| p95 Latency | Response time for 95% of requests | ~200ms at rest |
| Request Rate | Requests per second | Rises when traffic runs |
| Success vs Error | Time series of good/bad requests | Two lines — green and red |
| Latency Percentiles | p50/p95/p99 over time | All lines around 200ms at rest |
| Error Budget Over Time | Budget trend | Flat or declining |
| Burn Rate (1h + 6h) | Both burn rate lines | High but stable |

**How to test:**

```bash
# Generate a spike and watch the dashboard
./generate-traffic.sh spike &
# Open Grafana — watch Request Rate panel spike, then return to 0
```

**Healthy result:** All 9 panels show data. Panels may look alarming
(high burn rate, low availability) — this is correct for the lab setup.

---

## Alertmanager — Alert routing

**What it is:** Receives alerts from Prometheus and routes them to the
right destination (Slack for critical, email for warning).

**URL:** `http://localhost:9093`

**How to use:**

| Task | How |
|---|---|
| View active alerts | http://localhost:9093 |
| Test alert pipeline | `./sre-lab.sh outage` then wait 15s |
| Check routing | http://localhost:9093/#/status |

**Alert routing:**

| Severity | Destination | Repeat interval |
|---|---|---|
| Critical | Slack #general | Every 1 hour |
| Warning | Email | Every 2 hours |
| Watchdog | Null (silenced) | — |
| Infrastructure | Null (silenced) | — |

**How to test:**

```bash
# Trigger AppDown alert
./sre-lab.sh outage

# Wait 15-20 seconds then check:
# 1. http://localhost:9090/alerts — AppDown should show FIRING
# 2. http://localhost:9093 — alert should appear
# 3. Slack — notification should arrive within 60 seconds

# Recover
./sre-lab.sh recover

# Check Slack receives resolved notification
```

**Healthy result:** Alert fires within 15s, Slack notified within 60s,
resolved notification arrives after recovery.

---

## Jaeger — Distributed tracing

**What it is:** Receives traces from your app via OpenTelemetry and lets
you see the full journey of each request including timing.

**URL:** `http://localhost:16686`

**How to use:**

1. Go to `http://localhost:16686`
2. Select service: `cloud-lab-api`
3. Click **Find Traces**
4. Click any trace to see spans

**How to test:**

```bash
# Send a request and capture its trace ID
curl http://localhost:8888/
# Response includes: "trace_id": "cc29c837e17a04c8..."

# Search for that trace in Jaeger:
# http://localhost:16686 → search by trace ID
```

**Healthy result:** Traces appear in Jaeger UI. Each trace shows the
request duration. Failed requests (500 errors) appear as error traces —
filter by `Error: true` to see only failures.

**Note:** Jaeger uses in-memory storage — traces reset when the pod restarts.

---

## Loki — Log aggregation

**What it is:** Collects structured JSON logs from all pods via Promtail
and makes them queryable in Grafana.

**How to use (via Grafana):**

1. Go to Grafana → Explore (compass icon)
2. Select **Loki** as the datasource
3. Run a query:

```logql
# All app logs
{namespace="app"}

# Only error logs
{namespace="app"} | json | level="WARNING"

# Logs for a specific pod
{namespace="app", pod="cloud-lab-69ff4558db-2hrzq"}

# Search for a specific trace ID
{namespace="app"} |= "cc29c837e17a04c8"
```

**How to test:**

```bash
# Generate some traffic
for i in {1..10}; do curl -s http://localhost:8888/ > /dev/null; done

# In Grafana Explore → Loki → query: {namespace="app"}
# Should see JSON log lines appearing
```

**Healthy result:** Log lines appear in Grafana with fields: timestamp,
level, message, trace_id, duration_ms.

---

## Chaos Mesh — Fault injection

**What it is:** Runs chaos scenarios as Kubernetes resources. Inject
pod failures, network delays, and CPU stress without shell scripts.

**How to use:**

```bash
# Pod kill — kills one pod every 60 seconds
./sre-lab.sh chaos pod-kill

# Network delay — adds 200ms latency for 5 minutes
./sre-lab.sh chaos network-delay

# CPU stress — 80% CPU on one pod for 3 minutes
./sre-lab.sh chaos cpu-stress

# Full outage — kills all pods immediately
./sre-lab.sh chaos full-outage

# Stop all chaos
./sre-lab.sh chaos stop
```

**How to test each scenario:**

**Pod kill:**
```bash
./sre-lab.sh traffic mixed &
./sre-lab.sh chaos pod-kill
kubectl get pods -n app -w
# Watch pods being terminated and replaced every 60s
# Expected: replacement pod ready within 20-30 seconds
./sre-lab.sh chaos stop
```

**Network delay:**
```bash
./sre-lab.sh traffic spike &
./sre-lab.sh chaos network-delay
# Watch Prometheus: slo:latency_p95_5m rises above 0.5
# Watch Grafana: latency panel climbs
# Expected: HighLatencyWarning fires after ~90 seconds
./sre-lab.sh chaos stop
```

**Full outage:**
```bash
./sre-lab.sh chaos full-outage
# Watch: http://localhost:9090/alerts — AppDown fires within 15s
# Watch: Slack receives critical notification within 60s
# Kubernetes automatically replaces all pods
# Expected: service recovers within 60 seconds automatically
```

**Healthy result for each:**

| Scenario | Expected outcome |
|---|---|
| Pod kill | K8s replaces pod in <30s, traffic continues |
| Network delay | HighLatencyWarning fires, resolves after chaos ends |
| CPU stress | kubectl top shows CPU spike, HPA may add replicas |
| Full outage | AppDown fires, Slack notified, auto-recovery in 60s |

---

## CI/CD Pipeline — GitHub Actions

**What it is:** Automated pipeline that runs on every push to main.

**How to view:** https://github.com/EkpesJames/sre-cloud-lab/actions

**Pipeline stages:**

```
Test → Build → Deploy
```

| Stage | What runs | Where |
|---|---|---|
| Test | ruff lint + 30 pytest tests | GitHub ubuntu-latest |
| Build | docker build + Trivy scan + push to GHCR | GitHub ubuntu-latest |
| Deploy | k3s pull + kubectl rollout + Slack notify | Self-hosted WSL2 |

**How to test:**

```bash
# Make any change and push
echo "# test" >> README.md
git add README.md
git commit -m "test: trigger pipeline"
git push origin main

# Watch: https://github.com/EkpesJames/sre-cloud-lab/actions
# Expected: all 3 jobs green within 3-5 minutes
```

**How to run tests locally:**

```bash
APP_ERROR_RATE=0.0 APP_LATENCY_SECONDS=0.0 \
  JAEGER_ENDPOINT=http://localhost:4317 \
  pytest tests/ -v
# Expected: 30 passed
```

**Healthy result:** Three green checkmarks in GitHub Actions.
Slack receives deployment notification.

---

## secrets-audit.sh — Secrets verification

**What it is:** Scans the project for exposed credentials and verifies
all secrets are properly managed.

**How to use:**

```bash
./sre-lab.sh secrets
# or directly:
bash secrets-audit.sh
```

**What it checks:**

1. `.env` is not tracked by git
2. No real credentials in committed files
3. `.env.example` has only placeholder values
4. Kubernetes Secrets exist in cluster
5. k3s registry credentials configured
6. All required variables set in `.env`
7. `alertmanager.yml` uses `${VAR}` placeholders not real values

**How to test:**

```bash
bash secrets-audit.sh
```

**Healthy result:**
```
✓ All secrets checks passed — no issues found
  Secrets are managed via:
  • .env file (local, not in git)
  • Kubernetes Secrets (cluster)
  • GitHub Actions Secrets (CI/CD)
  • k3s registries.yaml (image pull)
```

---

## Circuit breaker

**What it is:** Automatically stops sending requests to the app when
the error rate exceeds 50%. Returns 503 immediately instead of failing slowly.

**States:**
- `closed` — normal operation, requests flow through
- `open` — error rate too high, all requests rejected with 503
- `half_open` — trial period, one request allowed through

**How to test:**

```bash
# Check initial state
curl http://localhost:8888/health/circuit

# Send enough traffic to trip the breaker
for i in {1..50}; do curl -s http://localhost:8888/ > /dev/null; done

# Check state — should show "open"
curl http://localhost:8888/health/circuit

# Wait 30 seconds — should move to "half_open"
sleep 30
curl http://localhost:8888/health/circuit

# Send one successful request — should close
curl http://localhost:8888/
curl http://localhost:8888/health/circuit
# Should show "closed" with reset counters
```

**Healthy result:**
```json
{"state":"open","error_count":7,"total_count":14,"threshold":0.5,"timeout_seconds":30}
```
Then after 30s:
```json
{"state":"closed","error_count":0,"total_count":0,"threshold":0.5,"timeout_seconds":30}
```

**Note:** Each pod has its own circuit breaker. You may see different
states on different pods — this is expected behaviour.

---

## Health probes

**What they are:** Endpoints that Kubernetes uses to decide whether
to restart a pod or remove it from the load balancer.

| Probe | Endpoint | K8s action on failure |
|---|---|---|
| Liveness | `/health/live` | Restart the container |
| Readiness | `/health/ready` | Remove from load balancer |
| Startup | `/health/live` | Wait (up to 30s) before other probes start |

**How to test liveness:**

```bash
curl http://localhost:8888/health/live
# Expected: {"status":"alive","timestamp":1234567890.0}  HTTP 200
```

**How to test readiness:**

```bash
# Normal state
curl http://localhost:8888/health/ready
# Expected: {"status":"ready","dependency":"healthy",...}  HTTP 200

# Break the dependency
curl http://localhost:8888/health/dependency/break
curl http://localhost:8888/health/ready
# Expected: {"status":"not_ready","reason":"dependency_unavailable",...}  HTTP 503

# Restore
curl http://localhost:8888/health/dependency/restore
curl http://localhost:8888/health/ready
# Expected: HTTP 200 again
```

**Healthy result:** Liveness always 200. Readiness 200 when healthy,
503 when dependency down or circuit breaker open.

---

## HPA — Horizontal Pod Autoscaler

**What it is:** Automatically scales the number of app pods between
2 and 6 based on CPU utilisation.

**How to check:**

```bash
kubectl get hpa -n app
# Shows: current CPU %, min/max replicas, current replicas
```

**How to test:**

```bash
# Run CPU stress chaos to trigger scaling
./sre-lab.sh chaos cpu-stress

# Watch HPA react (may take 1-2 minutes)
kubectl get hpa -n app -w
kubectl get pods -n app -w

# Stop chaos
./sre-lab.sh chaos stop

# Watch scale back down (takes 2+ minutes due to stabilisation window)
```

**Healthy result:** Replicas increase when CPU > 60%, decrease back
to 2 when load drops. Scale-up is faster than scale-down by design.

---

## Complete end-to-end demo sequence

Run this to demonstrate the full lab in one session:

```bash
# 1. Start everything
./sre-lab.sh start

# 2. Establish baseline (terminal 1)
./generate-traffic.sh mixed &

# 3. Check metrics populated (wait 2 minutes)
# Prometheus: slo:success_rate_5m should return ~0.70

# 4. Trigger a chaos scenario (terminal 2)
./sre-lab.sh chaos pod-kill
# Watch: kubectl get pods -n app -w
# Watch: Grafana availability panel

# 5. Stop chaos, trigger an outage
./sre-lab.sh chaos stop
./sre-lab.sh outage
# Watch: http://localhost:9090/alerts — AppDown fires
# Watch: Slack — critical notification arrives

# 6. Recover
./sre-lab.sh recover
# Watch: AppDown resolves
# Watch: Slack — resolved notification arrives

# 7. Run secrets audit
./sre-lab.sh secrets

# 8. Stop everything
./sre-lab.sh stop
```

**Expected total time:** 15-20 minutes for full demo.
