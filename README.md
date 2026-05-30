# Cloud SRE Lab — Distributed Booking System

A production-grade SRE portfolio project demonstrating end-to-end reliability
engineering across a distributed microservices system — API Gateway, Booking
Service, and Payment Service — running on Kubernetes (k3s on WSL2).

**Repo:** https://github.com/EkpesJames/sre-cloud-lab

---

## Architecture

```
Client
  │
  ▼
API Gateway (cloud-lab)          port 8888
  │  SLO: 99% availability
  │  p95 < 500ms
  │
  ▼  POST /book
Booking Service                  port 8889
  │  SLO: 99.5% availability
  │  p95 < 300ms
  │
  ▼  POST /payments
Payment Service                  port 8890
     SLO: 99.9% availability
     p95 < 200ms

All three services feed into:
  Prometheus → Grafana → Alertmanager → Slack/Email
  Loki (logs) + Jaeger (traces)
  One trace ID flows through all three services
```

---

## Quick start

```bash
# 1. Clone
git clone https://github.com/EkpesJames/sre-cloud-lab.git
cd sre-cloud-lab

# 2. Configure credentials
cp .env.example .env
nano .env

# 3. Start everything
./sre-lab.sh start

# 4. Test the full booking flow
./sre-lab.sh book
```

---

## Access URLs

| Service | URL | Notes |
|---|---|---|
| API Gateway | http://localhost:8888 | Entry point for all requests |
| Booking Service | http://localhost:8889 | Direct access for testing |
| Payment Service | http://localhost:8890 | Direct access for testing |
| Grafana | http://localhost:3000 | admin/admin |
| Prometheus | http://localhost:9090 | Metrics + alerts |
| Alertmanager | http://localhost:9093 | Alert routing |
| Jaeger | http://localhost:16686 | Distributed traces |

---

## Project structure

```
sre-cloud-lab/
├── sre-lab.sh                    # Master control script
├── generate-traffic.sh           # Traffic simulation (7 profiles)
├── deploy-distributed.sh         # Build + deploy all services
├── secrets-audit.sh              # Secrets verification
├── capacity-baseline.sh          # Load testing
│
├── api-gateway/                  # API Gateway service
│   ├── gateway.py                # FastAPI app — routes to booking service
│   └── Dockerfile
│
├── booking-service/              # Booking Service
│   ├── booking.py                # Creates bookings, calls payment service
│   └── Dockerfile
│
├── payment-service/              # Payment Service
│   ├── payment.py                # Processes payments — strictest SLO
│   └── Dockerfile
│
├── app/                          # Shared (requirements.txt)
│   └── requirements.txt
├── requirements.txt              # Shared Python dependencies
│
├── k8s/
│   ├── namespaces/               # app + monitoring namespaces
│   ├── app/                      # API gateway K8s manifests
│   ├── booking/                  # Booking service K8s manifests
│   ├── payment/                  # Payment service K8s manifests
│   ├── gateway/                  # API gateway configmap (with BOOKING_SERVICE_URL)
│   └── monitoring/               # Helm values + PrometheusRules (per-service SLOs)
│
├── monitoring/                   # Prometheus + Alertmanager config
├── grafana/                      # Dashboards as code + provisioning
├── chaos/                        # Chaos Mesh scenarios
├── tests/                        # pytest test suite
├── runbooks/                     # Incident response guides
└── docs/                         # SLO, PRR, ADRs, postmortems
```

---

## Services

### API Gateway (`gateway.py`)
- Entry point for all client requests
- Routes `/book` to Booking Service
- Circuit breaker — opens at 50% error rate
- Retry with exponential backoff (1s/2s)
- SLO: 99% availability, p95 < 500ms
- Error rate: 30% (intentional for demo)

### Booking Service (`booking.py`)
- Creates booking records
- Calls Payment Service for every booking
- Circuit breaker — opens at 50% error rate
- Propagates trace context to Payment Service
- SLO: 99.5% availability, p95 < 300ms
- Error rate: 10%

### Payment Service (`payment.py`)
- Processes payments — strictest SLO
- No downstream dependencies
- SLO: 99.9% availability, p95 < 200ms
- Error rate: 5%

---

## SLOs

| Service | Availability | Latency p95 | Error budget |
|---|---|---|---|
| API Gateway | 99.0% | < 500ms | 7h 18m/month |
| Booking Service | 99.5% | < 300ms | 3h 39m/month |
| Payment Service | 99.9% | < 200ms | 43m/month |

SLOs tighten downstream — payment has the strictest because a payment failure
directly impacts revenue.

---

## Key SRE concepts demonstrated

| Concept | Implementation |
|---|---|
| Per-service SLOs | Different targets for each service |
| Error budget burn rate | Multi-window (1h + 6h) per service |
| Cascade failure detection | CascadeFailureDetected alert |
| Distributed tracing | Same trace ID across all three services |
| Circuit breaker | Independent per service, per pod |
| Graceful degradation | Gateway returns 502 when booking fails |
| Retry with backoff | API Gateway retries booking, booking retries payment |
| Structured logging | trace_id in every log line for correlation |

---

## Commands

```bash
# Start/stop
./sre-lab.sh start
./sre-lab.sh stop
./sre-lab.sh restart

# Test the distributed flow
./sre-lab.sh book                    # One test booking
./sre-lab.sh traffic bookings        # Sustained booking traffic
./sre-lab.sh traffic cascade         # Cascade failure simulation

# Chaos scenarios
./sre-lab.sh chaos payment-outage    # Kill payment → cascades up
./sre-lab.sh chaos pod-kill          # Kill gateway pods randomly
./sre-lab.sh chaos network-delay     # Add 200ms latency to gateway
./sre-lab.sh chaos stop              # Stop all chaos

# Service outage simulation
./sre-lab.sh outage payment          # Scale payment to 0
./sre-lab.sh outage all              # Full system outage
./sre-lab.sh recover all             # Restore everything

# Observability
./sre-lab.sh logs gateway            # API gateway logs
./sre-lab.sh logs booking            # Booking service logs
./sre-lab.sh logs payment            # Payment service logs
./sre-lab.sh logs all                # All service logs

# Utilities
./sre-lab.sh status                  # Full health check
./sre-lab.sh secrets                 # Secrets audit
./sre-lab.sh open                    # Show all URLs
```

---

## Observability

### Prometheus queries (per service)

```promql
# Success rates
slo:api_gateway:success_rate_5m
slo:booking_service:success_rate_5m
slo:payment_service:success_rate_5m

# Burn rates
slo:api_gateway:error_budget_burn_rate_1h
slo:booking_service:error_budget_burn_rate_1h
slo:payment_service:error_budget_burn_rate_1h

# Latency
slo:api_gateway:latency_p95_5m
slo:booking_service:latency_p95_5m
slo:payment_service:latency_p95_5m

# Business metrics
slo:booking_service:bookings_per_minute
slo:payment_service:payments_per_minute
slo:payment_service:revenue_per_minute
```

### Jaeger — cross-service tracing

Every `/book` request produces a trace visible in Jaeger showing spans from
all three services. Search by `trace_id` returned in the API response.

### Alerts

| Alert | Condition | Severity |
|---|---|---|
| APIGatewayHighErrorRate | Burn rate > 14.4x | Critical |
| BookingServiceHighErrorRate | Error rate > 5% | Warning |
| BookingServiceDown | Unreachable | Critical |
| PaymentServiceHighErrorRate | Error rate > 1% | Critical |
| PaymentServiceDown | Unreachable | Critical |
| PaymentServiceHighLatency | p95 > 200ms | Warning |
| CascadeFailureDetected | Both gateway and booking degraded | Critical |

---

## CI/CD pipeline

Every push to `main`:
```
Test → Build (3 images) → Trivy scan → Push to GHCR → Deploy to k3s → Slack notify
```

---

## Known WSL2 limitations

| Limitation | Impact |
|---|---|
| node-exporter disabled | No host CPU/memory metrics |
| Per-pod circuit breaker state | Each pod tracks independently |
| In-memory Jaeger storage | Traces reset on pod restart |
| NodePort not directly accessible | Use kubectl port-forward |
