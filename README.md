# Cloud SRE Lab

A production-grade SRE portfolio project running on Kubernetes (k3s on WSL2).
Demonstrates the full SRE toolkit — observability, alerting, chaos engineering,
CI/CD, and resilience patterns.

**Repo:** https://github.com/EkpesJames/sre-cloud-lab
**Stack:** Python · FastAPI · Kubernetes · Prometheus · Grafana · Loki · Jaeger · Chaos Mesh · GitHub Actions

---

## Quick start

```bash
# 1. Clone the repo
git clone https://github.com/EkpesJames/sre-cloud-lab.git
cd sre-cloud-lab

# 2. Copy and fill in credentials
cp .env.example .env
nano .env

# 3. Start everything
./sre-lab.sh start

# 4. Open in browser
# App          → http://localhost:8888
# Grafana      → http://localhost:3000  (admin/admin)
# Prometheus   → http://localhost:9090
# Alertmanager → http://localhost:9093
# Jaeger       → http://localhost:16686
```

---

## Prerequisites

| Tool | Install |
|---|---|
| WSL2 (Ubuntu 24.04) | Windows feature |
| Docker | `sudo apt install docker.io` |
| k3s | `curl -sfL https://get.k3s.io \| sh -` |
| Helm | `curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 \| bash` |
| kubectl | Included with k3s — copy kubeconfig: `sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config` |

---

## Project structure

```
sre-cloud-lab/
├── sre-lab.sh                  # Master control script
├── generate-traffic.sh         # Traffic simulation
├── secrets-audit.sh            # Secrets verification
├── capacity-baseline.sh        # Load testing
├── install-chaos-mesh.sh       # Chaos Mesh setup
├── app/
│   ├── main.py                 # FastAPI app
│   └── requirements.txt
├── docker/
│   └── Dockerfile
├── k8s/
│   ├── namespaces/             # K8s namespace definitions
│   ├── app/                    # App manifests (deployment, service, hpa, pdb)
│   └── monitoring/             # Helm values + PrometheusRule
├── monitoring/
│   ├── prometheus.yml          # Scrape config
│   ├── alerts.yml              # Alert rules
│   ├── recording_rules.yml     # SLI + error budget rules
│   └── alertmanager.yml        # Alert routing
├── grafana/
│   ├── dashboards/             # Dashboard JSON (as code)
│   └── provisioning/           # Auto-load config
├── chaos/                      # Chaos Mesh scenarios
├── tests/                      # pytest test suite
├── runbooks/                   # Incident response guides
├── docs/
│   ├── SLO.md                  # SLO definitions
│   ├── PRR.md                  # Production Readiness Review
│   ├── postmortem-*.md         # Completed postmortems
│   └── adr/                    # Architecture Decision Records
└── .github/workflows/ci.yml    # CI/CD pipeline
```

---

## The application

A FastAPI Python app that simulates a production microservice:

- **30% random error rate** — drives realistic SLO breach scenarios
- **200ms processing delay** — creates measurable latency
- **Circuit breaker** — opens at 50% errors, closes after 30s
- **Retry with backoff** — 3 attempts, 1s/2s/4s delays
- **Graceful shutdown** — drains in-flight requests on SIGTERM
- **OpenTelemetry tracing** — trace ID on every request
- **Structured JSON logging** — timestamp, level, trace_id, duration

### Endpoints

| Endpoint | Purpose |
|---|---|
| `GET /` | Main endpoint — 30% fail rate, 200ms delay |
| `GET /health/live` | Liveness probe — always 200 if process is alive |
| `GET /health/ready` | Readiness probe — 503 if circuit open or dependency down |
| `GET /health/circuit` | Circuit breaker state and counters |
| `GET /metrics` | Prometheus metrics |
| `GET /health/dependency/break` | Lab — simulate dependency failure |
| `GET /health/dependency/restore` | Lab — restore dependency |

---

## Master control script

All lab operations go through `./sre-lab.sh`:

```bash
# Lifecycle
./sre-lab.sh start              # Start k3s + all port-forwards
./sre-lab.sh stop               # Stop everything cleanly
./sre-lab.sh restart            # Stop then start
./sre-lab.sh status             # Health check all endpoints + pods

# Operations
./sre-lab.sh deploy             # Build + deploy app to Kubernetes
./sre-lab.sh logs [target]      # Tail logs (app|prometheus|grafana|alertmanager|jaeger)
./sre-lab.sh traffic [mode]     # Generate traffic
./sre-lab.sh chaos [type]       # Run chaos scenario
./sre-lab.sh outage             # Scale app to 0 replicas
./sre-lab.sh recover            # Restore app after outage

# Utilities
./sre-lab.sh secrets            # Run secrets audit
./sre-lab.sh open               # Print all access URLs
```

---

## SLOs

| SLO | Target | Alert |
|---|---|---|
| Availability | 99% success rate (30-day rolling) | Warning >5% errors, Critical >10% errors |
| Latency | p95 < 500ms | Warning >500ms, Critical >1000ms |

**Error budget:** 1% of requests per month (~7h 18m equivalent)

Full definition: `docs/SLO.md`

---

## Alerts

| Alert | Condition | Severity | Notification |
|---|---|---|---|
| AppDown | App unreachable | Critical | Slack |
| HighLatencyWarning | p95 > 500ms for 1m | Warning | Email |
| HighLatencyCritical | p95 > 1000ms for 2m | Critical | Slack |
| HighErrorRateWarning | Error rate > 5% for 1m | Warning | Email |
| HighErrorRateCritical | Error rate > 10% for 2m | Critical | Slack |
| ErrorBudgetBurnRateFast | Burn rate > 14.4x (1h) | Critical | Slack |
| ErrorBudgetBurnRateSlow | Burn rate > 6x (6h) | Warning | Email |

---

## CI/CD pipeline

Every push to `main` triggers:

```
Test (ubuntu-latest)
  └── pip install → ruff lint → 30 pytest tests

Build (ubuntu-latest, needs: test)
  └── docker build → Trivy CVE scan → push to GHCR

Deploy (self-hosted WSL2, needs: build)
  └── k3s pull → kubectl set image → rollout status → Slack notify
```

**GitHub Secrets required:**
- `PAT_TOKEN` — GitHub Personal Access Token (repo + write:packages)
- `SLACK_WEBHOOK_URL` — Slack incoming webhook URL

---

## Known WSL2 limitations

| Issue | Cause | Impact |
|---|---|---|
| node-exporter disabled | Host path mount restriction | No host CPU/memory metrics |
| NodePort not directly accessible | WSL2 network namespace | Use kubectl port-forward |
| Per-pod circuit breaker state | No shared cache | Each pod tracks independently |
| KubeAPIErrorBudgetBurn alert firing | Resource constraints | Routed to null receiver |

---

## Runbooks

| Alert | Runbook |
|---|---|
| AppDown | `runbooks/AppDown.md` |
| HighLatency | `runbooks/HighLatency.md` |
| HighErrorRate | `runbooks/HighErrorRate.md` |

---

## Architecture decisions

| Decision | Document |
|---|---|
| Why k3s over minikube | `docs/adr/ADR-001-k3s-over-minikube.md` |
| Why multi-window burn rate alerting | `docs/adr/ADR-002-burn-rate-alerting.md` |
| Why Loki over Elasticsearch | `docs/adr/ADR-003-loki-over-elasticsearch.md` |
