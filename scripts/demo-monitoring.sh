#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# demo-monitoring.sh — Submits GPU jobs to generate Grafana dashboard metrics
# Requires: kubectl, gum (brew install gum)
#
# Designed to run AFTER deploying with --monitoring / enableMonitoring=true.
# Submits jobs in a pattern that lights up all 4 dashboard panels:
#   Panel 1: GPU utilization per namespace (DCGM metrics)
#   Panel 2: Queue depth + admission wait times (Kueue pending workloads)
#   Panel 3: Preemption events (high-pri evicts low-pri)
#   Panel 4: GPU-hours per namespace (DCGM utilization × time)
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEMO_JOBS_DIR="$(cd "${SCRIPT_DIR}/../demo-jobs" && pwd)"

if ! command -v gum &>/dev/null; then
  echo "ERROR: gum is required. Install with: brew install gum"
  exit 1
fi

# --- Theme colors ---
C_GREEN=76
C_YELLOW=220
C_RED=196
C_BLUE=39
C_CYAN=87
C_DIM=243
C_WHITE=255

# --- Helpers (matching demo-walkthrough.sh style) ---
title()   { echo ""; gum style --border double --border-foreground $C_CYAN --foreground $C_CYAN --bold --padding "1 3" --width 64 --align center "$@"; }
section() { echo ""; gum style --border rounded --border-foreground $C_CYAN --foreground $C_WHITE --bold --padding "0 2" --width 64 "$@"; }
narrate() { gum style --foreground $C_YELLOW --padding "0 2" "$@"; }
note()    { gum style --foreground $C_DIM --padding "0 2" "$@"; }
run()     { gum style --foreground $C_DIM --padding "0 2" "$ $*"; eval "$@"; }
pause()   { echo ""; gum confirm --default=Yes --affirmative "Continue →" --negative "" 2>/dev/null || true; }

# ============================================================================
title "Monitoring Dashboard Demo" "Prometheus + Grafana + GPU Metrics"
# ============================================================================

# --- Step 0: Verify monitoring stack ---
section "Step 0: Verify monitoring stack"

if ! kubectl get svc -n monitoring prometheus-grafana &>/dev/null; then
  gum style --foreground $C_RED --bold --padding "0 2" \
    "⚠ Monitoring stack not found!" \
    "" \
    "Deploy with monitoring enabled first:" \
    "  azd env set enableMonitoring true && azd up" \
    "  OR: ./scripts/deploy.sh --monitoring"
  exit 1
fi

narrate "✓ Monitoring stack detected"
note "Starting Grafana port-forward in background..."

# Start port-forward (kill any existing one first)
kubectl port-forward -n monitoring svc/prometheus-grafana 3000:80 &>/dev/null &
PF_PID=$!

# Clean up port-forward AND demo jobs on exit/interrupt
cleanup() {
  echo ""
  gum style --foreground $C_DIM --padding "0 2" "Cleaning up demo jobs and port-forward..."
  kubectl delete -f "${DEMO_JOBS_DIR}/team-a-job-low.yaml" --ignore-not-found 2>/dev/null || true
  kubectl delete -f "${DEMO_JOBS_DIR}/team-a-job-high.yaml" --ignore-not-found 2>/dev/null || true
  kubectl delete -f "${DEMO_JOBS_DIR}/team-b-job-low.yaml" --ignore-not-found 2>/dev/null || true
  kubectl delete -f "${DEMO_JOBS_DIR}/team-b-job-high.yaml" --ignore-not-found 2>/dev/null || true
  kill $PF_PID 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# Verify port-forward started
sleep 2
if ! kill -0 "$PF_PID" 2>/dev/null; then
  gum style --foreground $C_YELLOW --padding "0 2" \
    "⚠ Port-forward failed (port 3000 may be in use)." \
    "Run manually: kubectl port-forward -n monitoring svc/prometheus-grafana 3000:80"
fi

narrate ""
narrate "🌐 Grafana: http://localhost:3000"
narrate "   Login:   admin / demo"
narrate ""
narrate "Open the 'GPU Cluster Overview' dashboard now."
pause

# --- Step 1: Fill both team queues ---
section "Step 1: Submit baseline jobs (fills team quotas)"

narrate "Submitting low-priority jobs for both teams."
narrate "This fills their guaranteed GPU quotas."

run "kubectl apply -f ${DEMO_JOBS_DIR}/team-a-job-low.yaml"
run "kubectl apply -f ${DEMO_JOBS_DIR}/team-b-job-low.yaml"

gum spin --spinner dot --title "Waiting for admission (15s)..." -- sleep 15

narrate "📊 Check Grafana → Panel 2 should show 0 pending workloads"
narrate "   (both jobs admitted within quota)"
run "kubectl get workloads -A --no-headers 2>/dev/null || true"
pause

# --- Step 2: Trigger borrowing + queue pressure ---
section "Step 2: Submit high-priority job (borrowing + queue pressure)"

narrate "Team A submits a high-priority job requesting 4 GPUs."
narrate "This exceeds their quota — they'll borrow from the shared pool."

run "kubectl apply -f ${DEMO_JOBS_DIR}/team-a-job-high.yaml"

gum spin --spinner dot --title "Waiting for admission (15s)..." -- sleep 15

narrate "📊 Check Grafana:"
narrate "   Panel 1 → GPU utilization across two namespaces"
narrate "   Panel 2 → Queue depth may spike briefly during admission"
run "kubectl get workloads -A --no-headers 2>/dev/null || true"
pause

# --- Step 3: Trigger preemption ---
section "Step 3: Team B high-priority job (triggers preemption!)"

narrate "Team B submits a high-priority job requesting 4 GPUs."
narrate "Not enough GPUs free → Kueue preempts Team A's LOW-priority job."
narrate ""
narrate "Watch Panel 3 for the preemption spike! ⚡"

run "kubectl apply -f ${DEMO_JOBS_DIR}/team-b-job-high.yaml"

gum spin --spinner dot --title "Waiting for preemption cycle (20s)..." -- sleep 20

narrate "📊 Check Grafana:"
narrate "   Panel 3 → Preemption event recorded!"
narrate "   Panel 2 → Team A's evicted job goes back to pending"

run "kubectl get workloads -A --no-headers 2>/dev/null || true"
pause

# --- Step 4: Observe accumulated metrics ---
section "Step 4: Let metrics accumulate"

narrate "Jobs are running. Metrics are flowing."
narrate "Leave this running for a few minutes to see:"
narrate "   Panel 1 → GPU utilization trends per namespace"
narrate "   Panel 4 → GPU-hours accumulating over time"
narrate ""
narrate "When you're done observing, continue to clean up."
pause

# --- Clean up ---
section "Clean Up"

narrate "Deleting all demo jobs..."
run "kubectl delete -f ${DEMO_JOBS_DIR}/team-a-job-low.yaml --ignore-not-found"
run "kubectl delete -f ${DEMO_JOBS_DIR}/team-a-job-high.yaml --ignore-not-found"
run "kubectl delete -f ${DEMO_JOBS_DIR}/team-b-job-low.yaml --ignore-not-found"
run "kubectl delete -f ${DEMO_JOBS_DIR}/team-b-job-high.yaml --ignore-not-found"

narrate "✓ All demo jobs cleaned up"

# ============================================================================
title "Demo Complete"
narrate "You saw:"
narrate "  • GPU utilization per namespace (Panel 1)"
narrate "  • Queue depth and admission wait times (Panel 2)"
narrate "  • Preemption events from priority scheduling (Panel 3)"
narrate "  • GPU-hours consumed per team namespace (Panel 4)"
narrate ""
narrate "Grafana port-forward will stop when this script exits."
