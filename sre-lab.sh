#!/bin/bash

# ─────────────────────────────────────────────────────────────────────────────
# sre-lab.sh — Master control script for Cloud SRE Lab
#
# Replaces: lab, startup.sh, shutdown.sh
#
# Usage:
#   ./sre-lab.sh start          Start k3s, wait for pods, open port-forwards
#   ./sre-lab.sh stop           Stop port-forwards and k3s cleanly
#   ./sre-lab.sh restart        Stop then start
#   ./sre-lab.sh status         Health check all endpoints and pods
#   ./sre-lab.sh deploy         Deploy/update app to Kubernetes
#   ./sre-lab.sh logs [pod]     Tail pod logs (default: app pods)
#   ./sre-lab.sh traffic [mode] Generate traffic (default: mixed)
#   ./sre-lab.sh chaos [type]   Run chaos scenario (pod-kill|network-delay|cpu-stress|full-outage)
#   ./sre-lab.sh chaos stop     Stop all running chaos scenarios
#   ./sre-lab.sh outage         Simulate full outage (scale to 0)
#   ./sre-lab.sh recover        Recover from outage (scale to 2)
#   ./sre-lab.sh secrets        Run secrets audit
#   ./sre-lab.sh open           Print all access URLs
# ─────────────────────────────────────────────────────────────────────────────

set -e

# ── Helpers ───────────────────────────────────────────────────────────────────
log()  { echo "[$(date '+%H:%M:%S')] $1"; }
ok()   { echo "[$(date '+%H:%M:%S')] ✓ $1"; }
warn() { echo "[$(date '+%H:%M:%S')] ⚠ $1"; }
fail() { echo "[$(date '+%H:%M:%S')] ✗ $1"; exit 1; }
header() {
  echo ""
  echo "════════════════════════════════════════"
  echo "  $1"
  echo "════════════════════════════════════════"
  echo ""
}

# ── Port-forward management ───────────────────────────────────────────────────
start_pf() {
  local name=$1 ns=$2 svc=$3 ports=$4
  kubectl port-forward -n "$ns" "svc/$svc" $ports \
    >> "/tmp/pf-${name}.log" 2>&1 &
  echo $! > "/tmp/pf-${name}.pid"
  ok "$name → http://localhost:${ports%%:*}"
}

stop_pf() {
  local name=$1
  local pidfile="/tmp/pf-${name}.pid"
  if [[ -f "$pidfile" ]]; then
    local pid
    pid=$(cat "$pidfile")
    kill "$pid" 2>/dev/null && ok "Stopped $name port-forward" || true
    rm -f "$pidfile"
  fi
}

stop_all_pf() {
  for svc in app prometheus grafana alertmanager jaeger; do
    stop_pf "$svc"
  done
  pkill -f "kubectl port-forward" 2>/dev/null || true
  ok "All port-forwards stopped"
}

start_all_pf() {
  log "Starting port-forwards..."
  start_pf "app"          "app"        "cloud-lab"                              "8888:80"
  start_pf "prometheus"   "monitoring" "kube-prometheus-kube-prome-prometheus"  "9090:9090"
  start_pf "grafana"      "monitoring" "kube-prometheus-grafana"                "3000:80"
  start_pf "alertmanager" "monitoring" "kube-prometheus-kube-prome-alertmanager" "9093:9093"
  start_pf "jaeger"       "monitoring" "jaeger"                                 "16686:16686"
  sleep 4
}

# ── Health checks ─────────────────────────────────────────────────────────────
check_endpoint() {
  local name=$1 url=$2
  local code
  code=$(curl -s -o /dev/null -w "%{http_code}" "$url" 2>/dev/null)
  if [[ "$code" == "200" ]]; then
    ok "$name"
  else
    warn "$name (HTTP $code)"
  fi
}

run_health_checks() {
  log "Health checks..."
  check_endpoint "App liveness       " "http://localhost:8888/health/live"
  check_endpoint "App readiness      " "http://localhost:8888/health/ready"
  check_endpoint "App circuit breaker" "http://localhost:8888/health/circuit"
  check_endpoint "App metrics        " "http://localhost:8888/metrics"
  check_endpoint "Prometheus         " "http://localhost:9090/-/healthy"
  check_endpoint "Grafana            " "http://localhost:3000/api/health"
  check_endpoint "Alertmanager       " "http://localhost:9093/-/healthy"
  check_endpoint "Jaeger             " "http://localhost:16686"
}

# ── Commands ──────────────────────────────────────────────────────────────────

cmd_start() {
  header "Cloud SRE Lab — Starting"

  log "Starting k3s..."
  sudo systemctl start k3s
  ok "k3s started"

  log "Waiting for node..."
  until kubectl get nodes 2>/dev/null | grep -q "Ready"; do
    echo "  ... waiting"; sleep 3
  done
  ok "Node ready"

  log "Waiting for app pods..."
  kubectl wait --for=condition=ready pod \
    -l app=cloud-lab -n app --timeout=120s
  ok "App pods ready"

  log "Waiting for monitoring stack..."
  for label in \
    "app.kubernetes.io/name=prometheus" \
    "app.kubernetes.io/name=grafana" \
    "app.kubernetes.io/name=alertmanager" \
    "app=jaeger"; do
    name=$(echo "$label" | cut -d= -f2)
    kubectl wait --for=condition=ready pod \
      -l "$label" -n monitoring \
      --timeout=120s 2>/dev/null \
      && ok "$name ready" \
      || warn "$name still starting"
  done

  stop_all_pf 2>/dev/null || true
  sleep 2
  start_all_pf
  run_health_checks
  cmd_open
}

cmd_stop() {
  header "Cloud SRE Lab — Stopping"

  pkill -f "generate-traffic" 2>/dev/null && ok "Traffic stopped" || true
  stop_all_pf
  sudo systemctl stop k3s
  ok "k3s stopped"

  echo ""
  echo "  All data preserved. Restart with:"
  echo "  ./sre-lab.sh start"
  echo ""
}

cmd_restart() {
  cmd_stop
  sleep 3
  cmd_start
}

cmd_status() {
  header "Cloud SRE Lab — Status"

  echo "  Pods:"
  kubectl get pods -n app --no-headers 2>/dev/null | \
    awk '{printf "  %-45s %s\n", $1, $3}' || warn "k3s not running"
  echo ""
  kubectl get pods -n monitoring --no-headers 2>/dev/null | \
    awk '{printf "  %-45s %s\n", $1, $3}'
  echo ""

  echo "  HPA:"
  kubectl get hpa -n app --no-headers 2>/dev/null | \
    awk '{printf "  %-20s replicas: %s/%s  cpu: %s\n", $1, $7, $6, $5}'
  echo ""

  run_health_checks
  echo ""
}

cmd_deploy() {
  header "Deploying to Kubernetes"

  # Load .env
  [[ -f .env ]] && export $(grep -v '^#' .env | grep -v '^$' | xargs)

  log "Building app image..."
  docker build -t cloud-lab:local -f docker/Dockerfile .
  ok "Image built"

  log "Importing into k3s..."
  docker save cloud-lab:local | sudo k3s ctr images import -
  ok "Image imported"

  log "Applying manifests..."
  kubectl apply -f k8s/namespaces/namespaces.yaml
  kubectl apply -f k8s/app/configmap.yaml

  # Create/update secrets
  kubectl create secret generic cloud-lab-secrets \
    --namespace=app \
    --from-literal=SLACK_WEBHOOK_URL="${SLACK_WEBHOOK_URL}" \
    --from-literal=SMTP_USERNAME="${SMTP_USERNAME}" \
    --from-literal=SMTP_PASSWORD="${SMTP_PASSWORD}" \
    --from-literal=SMTP_FROM="${SMTP_FROM}" \
    --from-literal=ALERT_EMAIL_TO="${ALERT_EMAIL_TO}" \
    --dry-run=client -o yaml | kubectl apply -f -

  kubectl apply -f k8s/app/deployment.yaml
  kubectl apply -f k8s/app/service.yaml
  kubectl apply -f k8s/app/pdb.yaml
  kubectl apply -f k8s/app/hpa.yaml

  log "Rolling restart..."
  kubectl rollout restart deployment/cloud-lab -n app
  kubectl rollout status deployment/cloud-lab -n app --timeout=120s
  ok "Deployment complete"

  kubectl get pods -n app
}

cmd_logs() {
  local target="${2:-app}"
  case "$target" in
    app)
      kubectl logs -n app -l app=cloud-lab -f --tail=50
      ;;
    prometheus)
      kubectl logs -n monitoring \
        prometheus-kube-prometheus-kube-prome-prometheus-0 -f --tail=50
      ;;
    grafana)
      kubectl logs -n monitoring -l app.kubernetes.io/name=grafana \
        --container grafana -f --tail=50
      ;;
    alertmanager)
      kubectl logs -n monitoring \
        alertmanager-kube-prometheus-kube-prome-alertmanager-0 \
        --container alertmanager -f --tail=50
      ;;
    jaeger)
      kubectl logs -n monitoring -l app=jaeger -f --tail=50
      ;;
    *)
      kubectl logs -n app "$target" -f --tail=50
      ;;
  esac
}

cmd_traffic() {
  local mode="${2:-mixed}"
  log "Starting traffic: $mode"
  ./generate-traffic.sh "$mode"
}

cmd_chaos() {
  local type="${2:-help}"
  case "$type" in
    pod-kill)
      log "Applying pod-kill chaos..."
      kubectl apply -f chaos/pod-kill.yaml
      ok "Pod kill chaos running — one pod killed every 60s"
      echo "  Watch: kubectl get pods -n app -w"
      echo "  Stop:  ./sre-lab.sh chaos stop"
      ;;
    network-delay)
      log "Applying network-delay chaos..."
      kubectl apply -f chaos/network-delay.yaml
      ok "Network delay chaos running — 200ms latency for 5 minutes"
      echo "  Watch: http://localhost:9090 → slo:latency_p95_5m"
      echo "  Stop:  ./sre-lab.sh chaos stop"
      ;;
    cpu-stress)
      log "Applying CPU stress chaos..."
      kubectl apply -f chaos/cpu-stress.yaml
      ok "CPU stress chaos running — 80% CPU for 3 minutes"
      echo "  Watch: kubectl top pods -n app"
      echo "  Stop:  ./sre-lab.sh chaos stop"
      ;;
    full-outage)
      warn "Full outage — ALL pods will be killed"
      read -p "  Are you sure? (yes/no): " confirm
      [[ "$confirm" == "yes" ]] || { log "Cancelled"; exit 0; }
      kubectl apply -f chaos/full-outage.yaml
      ok "Full outage triggered — AppDown alert should fire within 15s"
      echo "  Watch: http://localhost:9090/alerts"
      echo "  Stop:  ./sre-lab.sh chaos stop"
      ;;
    stop)
      log "Stopping all chaos scenarios..."
      kubectl delete podchaos --all -n app 2>/dev/null && ok "PodChaos stopped" || true
      kubectl delete networkchaos --all -n app 2>/dev/null && ok "NetworkChaos stopped" || true
      kubectl delete stresschaos --all -n app 2>/dev/null && ok "StressChaos stopped" || true
      ok "All chaos stopped"
      ;;
    *)
      echo "  Usage: ./sre-lab.sh chaos [type]"
      echo ""
      echo "  Types:"
      echo "    pod-kill       Kill one pod every 60s"
      echo "    network-delay  Add 200ms latency for 5 minutes"
      echo "    cpu-stress     80% CPU stress for 3 minutes"
      echo "    full-outage    Kill all pods (triggers AppDown alert)"
      echo "    stop           Stop all running chaos scenarios"
      ;;
  esac
}

cmd_outage() {
  warn "Simulating full outage — scaling to 0 replicas"
  kubectl scale deployment cloud-lab -n app --replicas=0
  ok "App scaled to 0 — AppDown alert fires within 15s"
  echo "  Restore with: ./sre-lab.sh recover"
}

cmd_recover() {
  log "Recovering from outage..."
  kubectl scale deployment cloud-lab -n app --replicas=2
  kubectl wait --for=condition=ready pod \
    -l app=cloud-lab -n app --timeout=60s
  ok "App recovered — 2 pods running"
}

cmd_secrets() {
  bash secrets-audit.sh
}

cmd_open() {
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
  echo "  Quick commands:"
  echo "  ./sre-lab.sh traffic mixed          Generate realistic traffic"
  echo "  ./sre-lab.sh chaos pod-kill         Kill pods randomly"
  echo "  ./sre-lab.sh chaos network-delay    Inject 200ms latency"
  echo "  ./sre-lab.sh chaos full-outage      Trigger AppDown alert"
  echo "  ./sre-lab.sh outage                 Scale to 0 replicas"
  echo "  ./sre-lab.sh status                 Health check everything"
  echo "  ./sre-lab.sh secrets                Audit secrets"
  echo "  ./sre-lab.sh stop                   Shut down cleanly"
  echo "════════════════════════════════════════"
}

# ── Entry point ───────────────────────────────────────────────────────────────
case "${1:-help}" in
  start)    cmd_start ;;
  stop)     cmd_stop ;;
  restart)  cmd_restart ;;
  status)   cmd_status ;;
  deploy)   cmd_deploy ;;
  logs)     cmd_logs "$@" ;;
  traffic)  cmd_traffic "$@" ;;
  chaos)    cmd_chaos "$@" ;;
  outage)   cmd_outage ;;
  recover)  cmd_recover ;;
  secrets)  cmd_secrets ;;
  open)     cmd_open ;;
  *)
    echo ""
    echo "  Cloud SRE Lab — Master Control Script"
    echo ""
    echo "  Usage: ./sre-lab.sh <command>"
    echo ""
    echo "  Lifecycle:"
    echo "    start              Start k3s + all port-forwards"
    echo "    stop               Stop everything cleanly"
    echo "    restart            Stop then start"
    echo "    status             Health check all endpoints"
    echo "    deploy             Build + deploy app to Kubernetes"
    echo ""
    echo "  Operations:"
    echo "    logs [target]      Tail logs (app|prometheus|grafana|alertmanager|jaeger)"
    echo "    traffic [mode]     Generate traffic (mixed|spike|error-flood|slow-burn|slo-breach|normal)"
    echo "    chaos [type]       Run chaos (pod-kill|network-delay|cpu-stress|full-outage|stop)"
    echo "    outage             Scale app to 0 replicas"
    echo "    recover            Restore app after outage"
    echo ""
    echo "  Utilities:"
    echo "    secrets            Run secrets audit"
    echo "    open               Show all access URLs"
    echo ""
    ;;
esac
