#!/bin/bash

# ─────────────────────────────────────────────────────────────────────────────
# shutdown.sh — cleanly shuts down the Cloud SRE Lab environment
# All Kubernetes resources and data are preserved — nothing is deleted
# Run from the root of your cloud-sre-lab project
# ─────────────────────────────────────────────────────────────────────────────

log()  { echo "[$(date '+%H:%M:%S')] $1"; }
ok()   { echo "[$(date '+%H:%M:%S')] ✓ $1"; }

echo "════════════════════════════════════════"
echo "  Cloud SRE Lab — Shutting down"
echo "════════════════════════════════════════"
echo ""

# ── Step 1: Stop traffic generator if running ─────────────────────────────────
log "Stopping traffic generator..."
pkill -f "generate-traffic" 2>/dev/null && ok "Traffic generator stopped" || ok "No traffic generator running"

# ── Step 2: Stop all port-forwards ───────────────────────────────────────────
log "Stopping port-forwards..."

for svc in app prometheus grafana alertmanager; do
  pidfile="/tmp/pf-${svc}.pid"
  if [[ -f "$pidfile" ]]; then
    pid=$(cat "$pidfile")
    kill "$pid" 2>/dev/null && ok "Stopped $svc port-forward (PID $pid)" || true
    rm -f "$pidfile"
  fi
done

# Catch any strays
pkill -f "kubectl port-forward" 2>/dev/null || true
ok "All port-forwards stopped"

# ── Step 3: Stop k3s ─────────────────────────────────────────────────────────
log "Stopping k3s..."
sudo systemctl stop k3s
ok "k3s stopped"

echo ""
echo "════════════════════════════════════════"
echo "  Lab shut down cleanly"
echo "  All data preserved — restart with:"
echo "  ./startup.sh"
echo "════════════════════════════════════════"
