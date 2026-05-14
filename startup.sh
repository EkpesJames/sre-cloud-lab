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

# ── Step 1: Start k3s ─────────────────────────────────────────────────────────
log "Starting k3s..."
sudo systemctl start k3s
ok "k3s started"

# ── Step 2: Wait for node to be ready ────────────────────────────────────────
log "Waiting for node to be ready..."
until kubectl get nodes 2>/dev/null | grep -q "Ready"; do
  echo "  ... waiting for node"
  sleep 3
done
ok "Node is ready"

# ── Step 3: Wait for app pods ────────────────────────────────────────────────
log "Waiting for app pods to be running..."
kubectl wait --for=condition=ready pod \
  -l app=cloud-lab \
  -n app \
  --timeout=120s
ok "App pods ready"

# ── Step 4: Wait for monitoring pods ─────────────────────────────────────────
log "Waiting for Prometheus to be ready..."
kubectl wait --for=condition=ready pod \
  -l app.kubernetes.io/name=prometheus \
  -n monitoring \
  --timeout=120s 2>/dev/null && ok "Prometheus ready" || warn "Prometheus taking longer — continuing"

log "Waiting for Grafana to be ready..."
kubectl wait --for=condition=ready pod \
  -l app.kubernetes.io/name=grafana \
  -n monitoring \
  --timeout=120s 2>/dev/null && ok "Grafana ready" || warn "Grafana taking longer — continuing"

# ── Step 5: Kill any stale port-forwards ─────────────────────────────────────
log "Cleaning up any stale port-forwards..."
pkill -f "kubectl port-forward" 2>/dev/null || true
sleep 2
ok "Port-forwards cleared"

# ── Step 6: Start all port-forwards in background ────────────────────────────
log "Starting port-forwards..."

kubectl port-forward -n app svc/cloud-lab 8888:80 \
  >> /tmp/pf-app.log 2>&1 &
echo $! > /tmp/pf-app.pid
ok "App port-forward started (8888)"

kubectl port-forward -n monitoring \
  svc/kube-prometheus-kube-prome-prometheus 9090:9090 \
  >> /tmp/pf-prometheus.log 2>&1 &
echo $! > /tmp/pf-prometheus.pid
ok "Prometheus port-forward started (9090)"

kubectl port-forward -n monitoring \
  svc/kube-prometheus-grafana 3000:80 \
  >> /tmp/pf-grafana.log 2>&1 &
echo $! > /tmp/pf-grafana.pid
ok "Grafana port-forward started (3000)"

kubectl port-forward -n monitoring \
  svc/kube-prometheus-kube-prome-alertmanager 9093:9093 \
  >> /tmp/pf-alertmanager.log 2>&1 &
echo $! > /tmp/pf-alertmanager.pid
ok "Alertmanager port-forward started (9093)"

# Give port-forwards a moment to bind
sleep 3

# ── Step 7: Health checks ─────────────────────────────────────────────────────
echo ""
log "Running health checks..."

check() {
  local name=$1 url=$2
  local code
  code=$(curl -s -o /dev/null -w "%{http_code}" "$url" 2>/dev/null)
  if [[ "$code" == "200" ]]; then
    ok "$name → $url"
  else
    warn "$name → $url (HTTP $code — may still be starting)"
  fi
}

check "App          " "http://localhost:8888/health/live"
check "App metrics  " "http://localhost:8888/metrics"
check "Prometheus   " "http://localhost:9090/-/healthy"
check "Grafana      " "http://localhost:3000/api/health"
check "Alertmanager " "http://localhost:9093/-/healthy"

# ── Step 8: Summary ───────────────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════"
echo "  Access URLs"
echo "════════════════════════════════════════"
echo ""
echo "  App          → http://localhost:8888"
echo "  Prometheus   → http://localhost:9090"
echo "  Grafana      → http://localhost:3000  (admin/admin)"
echo "  Alertmanager → http://localhost:9093"
echo ""
echo "  Pod status:"
kubectl get pods -n app --no-headers | awk '{printf "  %-40s %s\n", $1, $3}'
kubectl get pods -n monitoring --no-headers | awk '{printf "  %-40s %s\n", $1, $3}'
echo ""
echo "  To generate traffic: ./generate-traffic.sh mixed"
echo "  To shut down:        ./shutdown.sh"
echo ""
echo "════════════════════════════════════════"
echo "  Lab is ready"
echo "════════════════════════════════════════"
