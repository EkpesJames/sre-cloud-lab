#!/bin/bash

# ─────────────────────────────────────────────────────────────────────────────
# shutdown.sh — cleanly shuts down the Cloud SRE Lab
# All data preserved — restart with ./startup.sh
# ─────────────────────────────────────────────────────────────────────────────

log() { echo "[$(date '+%H:%M:%S')] $1"; }
ok()  { echo "[$(date '+%H:%M:%S')] ✓ $1"; }

echo "════════════════════════════════════════"
echo "  Cloud SRE Lab — Shutting down"
echo "════════════════════════════════════════"
echo ""

# Stop traffic generator
log "Stopping traffic generator..."
pkill -f "generate-traffic" 2>/dev/null && ok "Traffic generator stopped" || ok "None running"

# Stop port-forwards by PID file
log "Stopping port-forwards..."
for svc in app prometheus grafana alertmanager jaeger; do
  pidfile="/tmp/pf-${svc}.pid"
  if [[ -f "$pidfile" ]]; then
    pid=$(cat "$pidfile")
    kill "$pid" 2>/dev/null && ok "Stopped $svc (PID $pid)" || true
    rm -f "$pidfile"
  fi
done
pkill -f "kubectl port-forward" 2>/dev/null || true
ok "All port-forwards stopped"

# Stop k3s
log "Stopping k3s..."
sudo systemctl stop k3s
ok "k3s stopped"

echo ""
echo "════════════════════════════════════════"
echo "  Shutdown complete"
echo "  Restart with: ./startup.sh"
echo "════════════════════════════════════════"
