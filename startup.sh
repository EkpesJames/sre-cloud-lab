#!/bin/bash

# ─────────────────────────────────────────────────────────────────────────────
# startup.sh — starts the full Cloud SRE Lab environment
# Run from the root of your cloud-sre-lab project
# ─────────────────────────────────────────────────────────────────────────────

set -e

log()  { echo "[$(date '+%H:%M:%S')] $1"; }
ok()   { echo "[$(date '+%H:%M:%S')] ✓ $1"; }
warn() { echo "[$(date '+%H:%M:%S')] ⚠ $1"; }

echo "════════════════════════════════════════"
echo "  Cloud SRE Lab — Starting up"
echo "════════════════════════════════════════"
echo ""

# ── Step 1: Start k3s ────────────────────────────────────────────────────────
log "Starting k3s..."
sudo systemctl start k3s
ok "k3s started"

# ── Step 2: Wait for node ────────────────────────────────────────────────────
log "Waiting for node to be ready..."
until kubectl get nodes 2>/dev/null | grep -q "Ready"; do
  echo "  ... waiting for node"
  sleep 3
done
ok "Node is ready"

# ── Step 3: Wait for app pods ────────────────────────────────────────────────
log "Waiting for app pods..."
kubectl wait --for=condition=ready pod \
  -l app=cloud-lab -n app --timeout=120s
ok "App pods ready"

# ── Step 4: Wait for monitoring pods ─────────────────────────────────────────
for component in "app.kubernetes.io/name=prometheus" \
                 "app.kubernetes.io/name=grafana" \
                 "app.kubernetes.io/name=alertmanager" \
                 "app=jaeger"; do
  name=$(echo $component | cut -d= -f2)
  log "Waiting for $name..."
  kubectl wait --for=condition=ready pod \
    -l "$component" -n monitoring \
    --timeout=120s 2>/dev/null && ok "$name ready" || warn "$name still starting"
done

# ── Step 5: Kill stale port-forwards ─────────────────────────────────────────
log "Clearing stale port-forwards..."
pkill -f "kubectl port-forward" 2>/dev/null || true
sleep 2
ok "Port-forwards cleared"

# ── Step 6: Start port-forwards ──────────────────────────────────────────────
log "Starting port-forwards..."

start_pf() {
  local name=$1 ns=$2 svc=$3 ports=$4
  kubectl port-forward -n "$ns" "svc/$svc" $ports \
    >> "/tmp/pf-${name}.log" 2>&1 &
  echo $! > "/tmp/pf-${name}.pid"
  ok "$name ($ports)"
}

start_pf "app"          "app"        "cloud-lab"                                 "8888:80"
start_pf "prometheus"   "monitoring" "kube-prometheus-kube-prome-prometheus"     "9090:9090"
start_pf "grafana"      "monitoring" "kube-prometheus-grafana"                   "3000:80"
start_pf "alertmanager" "monitoring" "kube-prometheus-kube-prome-alertmanager"   "9093:9093"
start_pf "jaeger"       "monitoring" "jaeger"                                    "16686:16686"

sleep 4

# ── Step 7: Health checks ────────────────────────────────────────────────────
echo ""
log "Health checks..."

check() {
  local name=$1 url=$2
  local code=$(curl -s -o /dev/null -w "%{http_code}" "$url" 2>/dev/null)
  [[ "$code" == "200" ]] && ok "$name" || warn "$name (HTTP $code)"
}

check "App liveness      " "http://localhost:8888/health/live"
check "App readiness     " "http://localhost:8888/health/ready"
check "App circuit breaker" "http://localhost:8888/health/circuit"
check "App metrics       " "http://localhost:8888/metrics"
check "Prometheus        " "http://localhost:9090/-/healthy"
check "Grafana           " "http://localhost:3000/api/health"
check "Alertmanager      " "http://localhost:9093/-/healthy"
check "Jaeger            " "http://localhost:16686"

# ── Step 8: Summary ──────────────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════"
echo "  Access URLs"
echo "════════════════════════════════════════"
echo ""
echo "  App            → http://localhost:8888"
echo "  Prometheus     → http://localhost:9090"
echo "  Grafana        → http://localhost:3000  (admin/admin)"
echo "  Alertmanager   → http://localhost:9093"
echo "  Jaeger         → http://localhost:16686"
echo ""
echo "  Pod status:"
kubectl get pods -n app --no-headers | awk '{printf "  %-40s %s\n", $1, $3}'
kubectl get pods -n monitoring --no-headers | awk '{printf "  %-40s %s\n", $1, $3}'
echo ""
echo "  Generate traffic : ./generate-traffic.sh mixed"
echo "  Shut down        : ./shutdown.sh"
echo ""
echo "════════════════════════════════════════"
echo "  Lab is ready"
echo "════════════════════════════════════════"
