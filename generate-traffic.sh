#!/bin/bash

# ─────────────────────────────────────────────────────────────────────────────
# generate-traffic.sh — Realistic traffic simulation for Cloud Lab
#
# Usage:
#   ./generate-traffic.sh normal       # Steady baseline traffic
#   ./generate-traffic.sh spike        # Sudden traffic spike
#   ./generate-traffic.sh error-flood  # High error rate scenario
#   ./generate-traffic.sh slow-burn    # Sustained load over time
#   ./generate-traffic.sh slo-breach   # Simulate an SLO breach scenario
#   ./generate-traffic.sh mixed        # Random realistic mix (default)
# ─────────────────────────────────────────────────────────────────────────────

BASE_URL="http://localhost:8080"
CONCURRENCY=5

# ── Helpers ───────────────────────────────────────────────────────────────────

log() { echo "[$(date '+%H:%M:%S')] $1"; }

send_request() {
  local endpoint="${1:-/}"
  local status
  status=$(curl -s -o /dev/null -w "%{http_code}" "${BASE_URL}${endpoint}" 2>/dev/null)
  echo "$status"
}

burst() {
  local count=$1
  local endpoint="${2:-/}"
  local delay="${3:-0.05}"
  local success=0 fail=0

  for ((i=1; i<=count; i++)); do
    status=$(send_request "$endpoint")
    if [[ "$status" == "200" ]]; then ((success++)); else ((fail++)); fi
    sleep "$delay"
  done

  log "Burst complete — ${count} requests | OK: ${success} | Fail: ${fail}"
}

parallel_burst() {
  local count=$1
  local endpoint="${2:-/}"
  log "Parallel burst: ${count} concurrent requests to ${endpoint}"
  for ((i=1; i<=count; i++)); do
    curl -s -o /dev/null "${BASE_URL}${endpoint}" &
  done
  wait
  log "Parallel burst complete"
}

# ── Traffic Profiles ──────────────────────────────────────────────────────────

profile_normal() {
  log "Profile: NORMAL — steady baseline traffic for 2 minutes"
  for ((round=1; round<=12; round++)); do
    log "Round ${round}/12 — sending 10 requests"
    burst 10 "/" 0.1
    sleep 10
  done
}

profile_spike() {
  log "Profile: SPIKE — normal → spike → recovery"

  log "Phase 1: Normal baseline (30s)"
  burst 30 "/" 0.1

  log "Phase 2: Traffic spike — 100 concurrent requests"
  parallel_burst 100 "/"
  sleep 2
  parallel_burst 100 "/"
  sleep 2
  parallel_burst 50 "/"

  log "Phase 3: Recovery — back to normal (30s)"
  burst 30 "/" 0.1

  log "Spike profile complete"
}

profile_error_flood() {
  log "Profile: ERROR FLOOD — hammering bad endpoints to drive up error rate"

  log "Phase 1: Warm up with normal traffic"
  burst 20 "/" 0.1

  log "Phase 2: Error flood — hitting nonexistent endpoints"
  for ((i=1; i<=50; i++)); do
    curl -s -o /dev/null "${BASE_URL}/nonexistent" &
    curl -s -o /dev/null "${BASE_URL}/broken" &
    curl -s -o /dev/null "${BASE_URL}/" &
  done
  wait

  log "Phase 3: Mixed error + success"
  burst 30 "/" 0.05

  log "Error flood profile complete"
}

profile_slow_burn() {
  log "Profile: SLOW BURN — sustained load for 5 minutes"
  local duration=300
  local start
  start=$(date +%s)

  while true; do
    now=$(date +%s)
    elapsed=$((now - start))
    [[ $elapsed -ge $duration ]] && break

    remaining=$((duration - elapsed))
    log "Slow burn — ${elapsed}s elapsed, ${remaining}s remaining"
    burst 15 "/" 0.1
    sleep 5
  done

  log "Slow burn complete"
}

profile_slo_breach() {
  log "Profile: SLO BREACH — simulating conditions that breach 99% availability SLO"

  log "Phase 1: Establish normal baseline"
  burst 50 "/" 0.05

  log "Phase 2: Begin degradation — errors climbing"
  # The app already has 30% random error rate; hammer it hard to surface errors
  for ((i=1; i<=5; i++)); do
    parallel_burst 40 "/"
    sleep 3
  done

  log "Phase 3: Recovery period"
  burst 30 "/" 0.2

  log "SLO breach simulation complete — check Grafana error budget panel"
}

profile_mixed() {
  log "Profile: MIXED — randomised realistic traffic for 3 minutes"
  local duration=180
  local start
  start=$(date +%s)

  while true; do
    now=$(date +%s)
    elapsed=$((now - start))
    [[ $elapsed -ge $duration ]] && break

    action=$((RANDOM % 4))
    case $action in
      0)
        log "Mixed: small burst"
        burst $((RANDOM % 15 + 5)) "/" 0.1
        ;;
      1)
        log "Mixed: parallel burst"
        parallel_burst $((RANDOM % 20 + 10)) "/"
        ;;
      2)
        log "Mixed: quiet period"
        sleep $((RANDOM % 8 + 3))
        ;;
      3)
        log "Mixed: error mix"
        burst 10 "/" 0.05
        curl -s -o /dev/null "${BASE_URL}/nonexistent" &
        curl -s -o /dev/null "${BASE_URL}/broken" &
        wait
        ;;
    esac
    sleep 2
  done

  log "Mixed profile complete"
}

# ── Entry Point ───────────────────────────────────────────────────────────────

PROFILE="${1:-mixed}"
log "Starting traffic profile: ${PROFILE^^}"
log "Target: ${BASE_URL}"
echo "────────────────────────────────────────────────"

case "$PROFILE" in
  normal)      profile_normal ;;
  spike)       profile_spike ;;
  error-flood) profile_error_flood ;;
  slow-burn)   profile_slow_burn ;;
  slo-breach)  profile_slo_breach ;;
  mixed)       profile_mixed ;;
  *)
    echo "Unknown profile: $PROFILE"
    echo "Usage: $0 {normal|spike|error-flood|slow-burn|slo-breach|mixed}"
    exit 1
    ;;
esac

log "Done."

