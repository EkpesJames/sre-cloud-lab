# Cloud SRE Lab

A production-grade Site Reliability Engineering portfolio project demonstrating
end-to-end SRE practices — from SLO definition and error budget tracking through
to Kubernetes deployment, distributed tracing, chaos engineering, and a full
CI/CD pipeline.

Built on WSL2 using k3s, this lab runs entirely locally and mirrors the tooling
and practices used by SRE teams at scale.

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                        GitHub Actions CI/CD                      │
│          lint → test → build → scan (Trivy) → push → deploy     │
└───────────────────────────┬─────────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────────┐
│                    k3s Kubernetes Cluster (WSL2)                  │
│                                                                   │
│  ┌─────────────────────────────────┐                             │
│  │         app namespace           │                             │
│  │                                 │                             │
│  │  ┌──────────┐  ┌──────────┐    │                             │
│  │  │ cloud-lab│  │ cloud-lab│    │  ← 2–6 replicas (HPA)      │
│  │  │  pod 1   │  │  pod 2   │    │                             │
│  │  └──────────┘  └──────────┘    │                             │
│  │   FastAPI + OpenTelemetry       │                             │
│  │   Circuit breaker + Retry       │                             │
│  │   /health/live + /health/ready  │                             │
│  └─────────────┬───────────────────┘                             │
│                │ metrics + traces + logs                         │
│                ▼                                                 │
│  ┌─────────────────────────────────┐                             │
│  │      monitoring namespace       │                             │
│  │                                 │                             │
│  │  Prometheus  → recording rules  │                             │
│  │  Alertmanager→ Slack + email    │                             │
│  │  Grafana     → SRE dashboard    │                             │
│  │  Loki        → log aggregation  │                             │
│  │  Jaeger      → distributed traces│                            │
│  │  kube-state-metrics             │                             │
│  └─────────────────────────────────┘                             │
└─────────────────────────────────────────────────────────────────┘
```

---

## What this project demonstrates

| SRE Practice | Implementation |
|---|---|
| SLO definition | 99% availability, p95 < 500ms — documented in `docs/SLO.md` |
| Error budget tracking | Prometheus recording rules + burn rate alerts |
| Multi-window burn rate alerting | 1h fast burn (14.4x) + 6h slow burn (6x) |
| Observability — metrics | Prometheus + Grafana, 9-panel SRE dashboard |
| Observability — logs | Loki + Promtail, structured JSON logging |
| Observability — traces | OpenTelemetry + Jaeger, trace ID in every response |
| Kubernetes deployment | Deployment, Service, HPA, PDB, ConfigMap, Secrets |
| Health probes | Liveness, readiness, and startup probes |
| Security hardening | Non-root container, read-only filesystem, K8s Secrets |
| Circuit breaker | Opens at 50% error rate, half-open after 30s |
| Retry with backoff | Tenacity — 3 attempts, exponential backoff 1s/2s/4s |
| Graceful shutdown | SIGTERM handling — zero dropped requests on rolling update |
| Chaos engineering | Pod kill, network delay, CPU stress scenarios |
| CI/CD pipeline | GitHub Actions — test, build, Trivy scan, push, deploy |
| Runbooks | AppDown, HighLatency, HighErrorRate — full diagnosis steps |
| Postmortem practice | Template + completed postmortems from chaos runs |
| Production Readiness Review | `docs/PRR.md` — pre-launch checklist |

---

## Tech stack used

| Layer | Tool |
|---|---|
| Application | Python, FastAPI, Uvicorn |
| Tracing | OpenTelemetry SDK, Jaeger |
| Resilience | Tenacity (circuit breaker + retry) |
| Metrics | Prometheus, prometheus-client |
| Dashboards | Grafana (dashboard as code) |
| Log aggregation | Loki, Promtail |
| Alerting | Alertmanager → Slack + email |
| Container runtime | Docker, containerd |
| Orchestration | Kubernetes (k3s on WSL2) |
| Package management | Helm |
| CI/CD | GitHub Actions, GHCR |
| Security scanning | Trivy |

---

## Project structure

```
cloud-sre-lab/
├── app/
│   ├── main.py                  # FastAPI app — metrics, tracing, circuit breaker
│   └── requirements.txt
├── docker/
│   └── Dockerfile               # Non-root, read-only filesystem, health check
├── k8s/
│   ├── namespaces/
│   │   └── namespaces.yaml      # app + monitoring namespaces
│   ├── app/
│   │   ├── deployment.yaml      # 3 replicas, probes, resource limits, security
│   │   ├── service.yaml         # ClusterIP + NodePort
│   │   ├── configmap.yaml       # App config — error rate, latency, Jaeger endpoint
│   │   ├── hpa.yaml             # HPA — 2 to 6 replicas on CPU
│   │   ├── pdb.yaml             # PodDisruptionBudget — min 2 available
│   │   └── secret.template.yaml # Secret structure reference
│   └── monitoring/
│       ├── kube-prometheus-stack-values.yaml
│       ├── loki-stack-values.yaml
│       ├── prometheus-rules.yaml  # PrometheusRule CRD — alerts + recording rules
│       └── jaeger.yaml
├── monitoring/
│   ├── prometheus.yml           # Scrape config (Docker mode)
│   ├── alerts.yml               # Alert rules
│   ├── recording_rules.yml      # SLI + error budget recording rules
│   └── alertmanager.yml         # Routing — Slack (critical) + email (warning)
├── grafana/
│   ├── dashboards/
│   │   └── sre-overview.json    # 9-panel SRE dashboard as code
│   └── provisioning/
│       ├── datasources.yml
│       └── dashboards.yml
├── nginx/
│   └── nginx.conf               # Load balancer config (Docker mode)
├── chaos/                       # Chaos Mesh manifests (Week 5)
├── runbooks/
│   ├── AppDown.md
│   ├── HighLatency.md
│   └── HighErrorRate.md
├── docs/
│   ├── SLO.md                   # SLO definitions + error budget policy
│   ├── postmortem-template.md
│   └── PRR.md                   # Production Readiness Review
├── .github/
│   └── workflows/
│       └── ci.yml               # GitHub Actions CI/CD pipeline
├── generate-traffic.sh          # 6 traffic profiles for testing
├── startup.sh                   # Start k3s + all port-forwards
├── shutdown.sh                  # Clean shutdown
├── lab                          # Docker mode control script
├── .env.example                 # Environment variable template
└── .gitignore
```

---

## Quick start

### Prerequisites
- WSL2 (Ubuntu 24.04)
- Docker
- k3s (`curl -sfL https://get.k3s.io | sh -`)
- Helm 3 (`curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash`)

### 1. Clone and configure

```bash
git clone https://github.com/YOUR_USERNAME/cloud-sre-lab.git
cd cloud-sre-lab

# Copy and fill in credentials
cp .env.example .env
nano .env
```

### 2. Deploy to Kubernetes

```bash
# Deploy app
bash k8s/k8s-apply.sh

# Deploy observability stack
bash week2-deploy.sh

# Deploy tracing + resilience
bash week3-deploy.sh
```

### 3. Start the lab

```bash
./startup.sh
```

### 4. Access the tools

| Tool | URL | Credentials |
|---|---|---|
| App | http://localhost:8888 | — |
| Prometheus | http://localhost:9090 | — |
| Grafana | http://localhost:3000 | admin / admin |
| Alertmanager | http://localhost:9093 | — |
| Jaeger | http://localhost:16686 | — |

### 5. Generate traffic

```bash
# Six profiles available
./generate-traffic.sh mixed        # randomised realistic traffic
./generate-traffic.sh spike        # sudden traffic spike
./generate-traffic.sh error-flood  # drive up error rate
./generate-traffic.sh slow-burn    # sustained load
./generate-traffic.sh slo-breach   # trigger SLO breach scenario
./generate-traffic.sh normal       # steady baseline
```

### 6. Shut down

```bash
./shutdown.sh
```

---

## SLOs

| SLO | Target | Alert threshold |
|---|---|---|
| Availability | 99.0% success rate (30-day rolling) | Warning > 5% errors, Critical > 10% errors |
| Latency | p95 < 500ms | Warning > 500ms, Critical > 1000ms |

Error budget: 1% of requests per month may fail (~7h 18m equivalent).

See `docs/SLO.md` for full definition, burn rate policy, and review process.

---

## Observability

### Metrics — Prometheus + Grafana
Key recording rules:
- `slo:success_rate_5m` — aggregated availability across all pods
- `slo:latency_p95_5m` — p95 latency across all pods
- `slo:error_budget_burn_rate_1h` — fast burn rate (critical threshold: 14.4x)
- `slo:error_budget_burn_rate_6h` — slow burn rate (warning threshold: 6x)

### Logs — Loki + Promtail
Structured JSON logs from all pods. Correlate with metrics in Grafana using trace ID.

### Traces — OpenTelemetry + Jaeger
Every request carries a trace ID returned in the response body and written to logs.
Search traces in Jaeger at `http://localhost:16686`.

---

## Resilience patterns

### Circuit breaker
- Opens when error rate exceeds 50% over 10+ requests
- Returns HTTP 503 immediately when open — no wasted capacity
- Enters half-open state after 30 seconds
- Closes on first successful trial request
- State visible at `/health/circuit` and in Prometheus as `circuit_breaker_state`

**Known behaviour:** Each pod maintains its own circuit breaker state.
In production, shared state (e.g. Redis) would synchronise across instances.

### Retry with exponential backoff
- Max 3 attempts on dependency calls
- Backoff: 1s → 2s → 4s
- Implemented with Tenacity

### Graceful shutdown
- Handles SIGTERM via FastAPI lifespan event
- Drains in-flight requests before exiting
- Prevents dropped requests during Kubernetes rolling updates

---

## Health endpoints

| Endpoint | Purpose | K8s probe |
|---|---|---|
| `/health/live` | Is the process alive? | Liveness |
| `/health/ready` | Is the app ready to serve? | Readiness |
| `/health/circuit` | Circuit breaker state | — |
| `/metrics` | Prometheus metrics | — |

---

## Runbooks

| Alert | Runbook | Severity |
|---|---|---|
| AppDown | `runbooks/AppDown.md` | Critical |
| HighLatencyWarning / Critical | `runbooks/HighLatency.md` | Warning / Critical |
| HighErrorRateWarning / Critical | `runbooks/HighErrorRate.md` | Warning / Critical |
| ErrorBudgetBurnRateFast | `runbooks/ErrorBudget.md` | Critical |

---

## Known limitations (WSL2)

| Limitation | Reason | Production equivalent |
|---|---|---|
| node-exporter disabled | WSL2 host path mount restriction | Enable on real Linux nodes |
| Per-pod circuit breaker state | No shared cache | Redis or distributed state store |
| In-memory trace storage (Jaeger) | Resets on pod restart | Jaeger with persistent backend |
| NodePort not accessible directly | WSL2 network namespace | LoadBalancer or Ingress on cloud |

---

## What I would add next

- Terraform for cloud deployment (AWS EKS or Azure AKS)
- Sealed Secrets for encrypted secrets in git
- Chaos Mesh for Kubernetes-native fault injection
- Multi-service SLO dashboard (premium vs standard tier)
- Grafana OnCall for on-call rotation simulation
- Rate limiting with SlowAPI
