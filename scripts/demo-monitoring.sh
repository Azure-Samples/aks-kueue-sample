#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# demo-monitoring.sh — Submits GPU training jobs to generate Grafana metrics
# Requires: kubectl, gum (brew install gum)
#
# Designed to run AFTER deploying with --monitoring / enableMonitoring=true.
# Submits jobs in a pattern that lights up all 5 dashboard panels:
#   Panel 1: GPU utilization per namespace (DCGM metrics)
#   Panel 2: Pending workloads per ClusterQueue (Kueue queue depth)
#   Panel 3: Preemption events (high-pri evicts low-pri)
#   Panel 4: Admission wait time p95 (Kueue histogram)
#   Panel 5: Active GPUs per namespace (DCGM utilization count)
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEMO_JOBS_DIR="$(cd "${SCRIPT_DIR}/../demo-jobs" && pwd)"

for cmd in gum jq; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "ERROR: $cmd is required. Install with: brew install $cmd"
    exit 1
  fi
done

# Detect GPU count from node allocatable resources
TOTAL_GPUS=$(kubectl get nodes -l gpu-type=nvidia-h100 -o json 2>/dev/null | \
  jq '[.items[].status.allocatable["nvidia.com/gpu"] // "0" | tonumber] | add // 0' 2>/dev/null || echo 0)
if [[ "$TOTAL_GPUS" -eq 0 ]]; then
  echo "WARNING: No GPU nodes detected. Demo may not work correctly."
  TOTAL_GPUS=8  # fallback for display purposes
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

# Clean up demo jobs and port-forward on exit/interrupt
cleanup() {
  echo ""
  gum style --foreground $C_DIM --padding "0 2" "Cleaning up demo jobs and port-forward..."
  kubectl delete -f "${DEMO_JOBS_DIR}/team-a-job-low.yaml" --ignore-not-found 2>/dev/null || true
  kubectl delete -f "${DEMO_JOBS_DIR}/team-a-job-high.yaml" --ignore-not-found 2>/dev/null || true
  kubectl delete -f "${DEMO_JOBS_DIR}/team-b-job-low.yaml" --ignore-not-found 2>/dev/null || true
  kubectl delete -f "${DEMO_JOBS_DIR}/team-b-job-high.yaml" --ignore-not-found 2>/dev/null || true
  kubectl delete -f "${DEMO_JOBS_DIR}/team-a-job-single-gpu.yaml" --ignore-not-found 2>/dev/null || true
  kubectl delete -f "${DEMO_JOBS_DIR}/team-b-job-single-gpu.yaml" --ignore-not-found 2>/dev/null || true
  kill "$PF_PID" 2>/dev/null || true
}

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

# Start port-forward — try port 3000, fall back to 8080
GRAFANA_PORT=3000
PF_PID=""
kubectl port-forward -n monitoring svc/prometheus-grafana "${GRAFANA_PORT}:80" &>/dev/null &
PF_PID=$!
sleep 2
if ! kill -0 "$PF_PID" 2>/dev/null; then
  GRAFANA_PORT=8080
  kubectl port-forward -n monitoring svc/prometheus-grafana "${GRAFANA_PORT}:80" &>/dev/null &
  PF_PID=$!
fi

trap cleanup EXIT INT TERM

# Verify port-forward started
sleep 2
if ! kill -0 "$PF_PID" 2>/dev/null; then
  gum style --foreground $C_YELLOW --padding "0 2" \
    "⚠ Port-forward failed (port ${GRAFANA_PORT} may be in use)." \
    "Run manually: kubectl port-forward -n monitoring svc/prometheus-grafana <PORT>:80"
fi

narrate ""
narrate "🌐 Grafana: http://localhost:${GRAFANA_PORT}"
narrate "   Login:   admin / demo"
narrate ""
narrate "Open the 'GPU Cluster Overview' dashboard now."
narrate ""
note "Tip: If panels show 'No data' initially, wait ~30s for Prometheus"
note "to scrape the first metrics from DCGM and Kueue."
pause

# --- Step 1+: Job submission (conditional on GPU count) ---
if [[ $TOTAL_GPUS -ge 4 ]]; then
  # --- Full demo: borrowing + preemption (4+ GPUs) ---
  section "Step 1: Submit baseline training jobs (fills team quotas)"

  narrate "Submitting low-priority training jobs for both teams (2 GPUs each)."
  narrate "  Team A: ResNet-18 on CIFAR-10  (2 GPUs)"
  narrate "  Team B: VGG-11 on CIFAR-10     (2 GPUs)"
  narrate ""
  narrate "This fills their guaranteed GPU quotas (2+2 = 4 of 8 GPUs)."

  run "kubectl apply -f ${DEMO_JOBS_DIR}/team-a-job-low.yaml"
  run "kubectl apply -f ${DEMO_JOBS_DIR}/team-b-job-low.yaml"

  gum spin --spinner dot --title "Waiting for pods to start training (45s)..." -- sleep 45

  narrate "📊 Check Grafana:"
  narrate "   Panel 1 → GPU utilization appearing for team-a and team-b"
  narrate "   Panel 2 → 0 pending workloads (both admitted within quota)"
  narrate "   Panel 5 → 4 active GPUs (2 per namespace)"
  run "kubectl get workloads -A --no-headers 2>/dev/null || true"
  pause

  # --- Step 2: Trigger borrowing + queue pressure ---
  section "Step 2: Submit Team A high-priority training (borrowing)"

  narrate "Team A submits a high-priority ResNet-50 on CIFAR-100 (4 GPUs)."
  narrate "Team A's quota is 2, so Kueue borrows 2 from the shared pool."
  narrate "Total usage: 4 (low) + 4 (high) = 8 GPUs — cluster is full."

  run "kubectl apply -f ${DEMO_JOBS_DIR}/team-a-job-high.yaml"

  gum spin --spinner dot --title "Waiting for admission + training start (45s)..." -- sleep 45

  narrate "📊 Check Grafana:"
  narrate "   Panel 1 → GPU utilization across both namespaces"
  narrate "   Panel 4 → Admission wait time recorded for team-a-cq"
  narrate "   Panel 5 → Active GPU count: 6 team-a, 2 team-b"
  run "kubectl get workloads -A --no-headers 2>/dev/null || true"
  pause

  # --- Step 3: Trigger preemption ---
  section "Step 3: Team B high-priority job (triggers preemption!)"

  narrate "Team B submits a high-priority DenseNet-121 on CIFAR-100 (4 GPUs)."
  narrate "Cluster is full (8/8). Kueue must preempt to make room."
  narrate ""
  narrate "How Kueue decides:"
  narrate "  1. team-b-cq has borrowWithinCohort: LowerPriority"
  narrate "     → can only preempt workloads with LOWER priority than team-b-high"
  narrate "  2. team-a-high is EQUAL priority (1000) → NOT a candidate"
  narrate "  3. Both low-pri jobs (priority 100) ARE candidates"
  narrate "  4. Evicting one low-pri frees 2 GPUs — not enough for 4 GPUs"
  narrate "     → Kueue evicts BOTH low-pri jobs to free 4 GPUs"
  narrate ""
  narrate "Watch Panels 2 & 3 for the preemption! ⚡"

  run "kubectl apply -f ${DEMO_JOBS_DIR}/team-b-job-high.yaml"

  gum spin --spinner dot --title "Waiting for preemption cycle (30s)..." -- sleep 30

  narrate "📊 Check Grafana:"
  narrate "   Panel 3 → Preemption events for both low-pri workloads"
  narrate "   Panel 2 → Two evicted low-pri jobs appear as pending"
  narrate "   Panel 4 → Wait time spike for re-queued workloads"
  narrate "   Panel 5 → GPUs shift: 4 team-a (high), 4 team-b (high)"

  run "kubectl get workloads -A --no-headers 2>/dev/null || true"
  pause

  # --- Step 4: Observe accumulated metrics ---
  section "Step 4: Let metrics accumulate"

  narrate "Both high-priority training jobs are running."
  narrate "  Team A: ResNet-50 on CIFAR-100 (4 GPUs)"
  narrate "  Team B: DenseNet-121 on CIFAR-100 (4 GPUs)"
  narrate "  Both low-pri jobs evicted and re-queued."
  narrate ""
  narrate "Leave this running for a few minutes to see:"
  narrate "   Panel 1 → GPU utilization trends per namespace"
  narrate "   Panel 5 → Active GPUs shifting between namespaces"
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

else
  # --- Small cluster demo: single-GPU jobs (1-3 GPUs) ---
  section "Step 1: Single-GPU Training (${TOTAL_GPUS} GPU cluster)"

  narrate "This cluster has ${TOTAL_GPUS} GPU(s) — using single-GPU jobs."
  narrate "Borrowing and preemption demos require 4+ GPUs."
  narrate ""

  narrate "Team A: ResNet-18 on CIFAR-10 (1 GPU)"
  run "kubectl apply -f ${DEMO_JOBS_DIR}/team-a-job-single-gpu.yaml"

  if [[ $TOTAL_GPUS -ge 2 ]]; then
    narrate "Team B: VGG-11 on CIFAR-10 (1 GPU)"
    run "kubectl apply -f ${DEMO_JOBS_DIR}/team-b-job-single-gpu.yaml"
  fi

  gum spin --spinner dot --title "Waiting for pods to start training (45s)..." -- sleep 45

  narrate "📊 Check Grafana:"
  narrate "   Panel 1 → GPU utilization per namespace"
  narrate "   Panel 5 → Active GPU count"
  run "kubectl get workloads -A --no-headers 2>/dev/null || true"
  pause

  # --- Observe metrics ---
  section "Step 2: Let metrics accumulate"

  narrate "Leave training running for a few minutes to see GPU utilization"
  narrate "trends in the Grafana dashboards."
  narrate ""
  narrate "When you're done observing, continue to clean up."
  pause

  # --- Clean up ---
  section "Clean Up"

  narrate "Deleting single-GPU demo jobs..."
  run "kubectl delete -f ${DEMO_JOBS_DIR}/team-a-job-single-gpu.yaml --ignore-not-found"
  run "kubectl delete -f ${DEMO_JOBS_DIR}/team-b-job-single-gpu.yaml --ignore-not-found"

  narrate "✓ All demo jobs cleaned up"
fi

# ============================================================================
title "Demo Complete"
if [[ $TOTAL_GPUS -ge 4 ]]; then
  narrate "You saw:"
  narrate "  • Real ML training generating GPU utilization (Panel 1)"
  narrate "  • Queue depth — pending workloads from preemption (Panel 2)"
  narrate "  • Preemption events: high-pri evicts both low-pri jobs (Panel 3)"
  narrate "  • Admission wait time per ClusterQueue (Panel 4)"
  narrate "  • Active GPUs shifting between namespaces (Panel 5)"
else
  narrate "You saw:"
  narrate "  • Real ML training generating GPU utilization (Panel 1)"
  narrate "  • Active GPU count per namespace (Panel 5)"
  narrate ""
  narrate "For the full demo with borrowing and preemption (Panels 2-4),"
  narrate "deploy with 4+ GPUs (e.g. Standard_ND96isr_H100_v5)."
fi
narrate ""
narrate "Grafana port-forward will stop when this script exits."
