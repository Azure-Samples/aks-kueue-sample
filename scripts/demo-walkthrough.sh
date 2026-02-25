#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# demo-walkthrough.sh — Interactive Kueue GPU scheduling demo
# Requires: gum (brew install gum), kubectl, jq
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEMO_JOBS_DIR="$(cd "${SCRIPT_DIR}/../demo-jobs" && pwd)"

if ! command -v gum &>/dev/null; then
  echo "ERROR: gum is required. Install with: brew install gum"
  exit 1
fi

# --- Theme colors (ANSI 256) ---
C_GREEN=76    # team A / success
C_YELLOW=220  # borrowed
C_RED=196     # evicted
C_BLUE=39     # team B
C_CYAN=87     # headers / boxes
C_DIM=243     # idle / dim text
C_WHITE=255

# --- Helpers ---
title()   { echo ""; gum style --border double --border-foreground $C_CYAN --foreground $C_CYAN --bold --padding "1 3" --width 64 --align center "$@"; }
section() { echo ""; gum style --border rounded --border-foreground $C_CYAN --foreground $C_WHITE --bold --padding "0 2" --width 64 "$@"; }
narrate() { gum style --foreground $C_YELLOW --padding "0 2" "$@"; }
note()    { gum style --foreground $C_DIM --padding "0 2" "$@"; }
run()     { gum style --foreground $C_DIM --padding "0 2" "$ $*"; eval "$@"; }
pause()   { echo ""; gum confirm --default=Yes --affirmative "Continue →" --negative "" 2>/dev/null || true; }

gpu_box() {
  local label="$1" color="$2"
  gum style --border rounded --border-foreground "$color" --foreground "$color" --padding "0 1" --width 10 "$label"
}

gpu_grid() {
  # Build 8-GPU visual. Args: label1 color1 label2 color2 ... (8 pairs)
  local boxes=()
  while [[ $# -ge 2 ]]; do
    boxes+=("$(gpu_box "$1" "$2")")
    shift 2
  done
  gum join --horizontal "${boxes[@]}"
}

# ============================================================================
title "GPU Scheduling with Kueue" "Fair Sharing & Preemption"
# ============================================================================

echo ""
narrate "Two ML teams share an 8-GPU H100 node."
narrate "Each team has a guaranteed allocation. A shared pool"
narrate "lets them borrow idle capacity. When contention happens,"
narrate "Kueue preempts borrowed resources automatically."

echo ""
gum join --horizontal \
  "$(gum style --border rounded --border-foreground $C_GREEN --foreground $C_GREEN --padding '0 2' --width 20 --align center 'Team A' '2 GPU nom.' '+4 borrow')" \
  "$(gum style --border rounded --border-foreground $C_DIM --foreground $C_DIM --padding '0 2' --width 20 --align center 'Shared' '4 GPU lend' '')" \
  "$(gum style --border rounded --border-foreground $C_BLUE --foreground $C_BLUE --padding '0 2' --width 20 --align center 'Team B' '2 GPU nom.' '+4 borrow')"

note "" 'Cohort "ml-org" — resources flow between all three queues.'
pause

# ============================================================================
title "Kueue 101" "How GPU Scheduling Works"
# ============================================================================

echo ""
gum style --border rounded --border-foreground $C_CYAN --padding "1 3" --width 64 \
  "ClusterQueue  — the budget" \
  "  Set by admins. How many GPUs a team can use." \
  "  Think: bank account with a spending limit." \
  "" \
  "LocalQueue    — the submission window" \
  "  Lives in a team's namespace. Users submit here." \
  "  Think: ATM that draws from the account." \
  "" \
  "Cohort        — the sharing agreement" \
  "  Groups queues together for borrowing/lending." \
  "  Think: credit union for GPU capacity."

echo ""
note "Admins manage ClusterQueues. Users only see LocalQueues."
pause

echo ""
narrate "How they connect:"
echo ""
gum style --foreground $C_CYAN --padding "0 2" \
  "  Job → LocalQueue → ClusterQueue → Cohort" \
  "         (user)       (admin)       (sharing)" \
  "" \
  "  team-a-lq → team-a-cq ─┐" \
  "                          ├── ml-org (borrow/lend)" \
  "  team-b-lq → team-b-cq ─┤" \
  "                          │" \
  "               shared-cq ─┘"
echo ""
gum style --foreground $C_WHITE --bold --padding "0 2" \
  "Key rule: Guaranteed quotas are sacred." \
  "Borrowed resources are reclaimed on contention."
pause

# ============================================================================
section "Step 1: What We're Working With"
# ============================================================================

narrate "One ND96isr H100 v5 node = 8 GPUs. Let's confirm:"
run "kubectl get nodes -o json | jq -r '.items[] | \"\(.metadata.name)  \(.status.allocatable[\"nvidia.com/gpu\"] // \"0\") GPUs\"'"
pause

narrate "The Kueue config — three ClusterQueues, one cohort:"
run "kubectl get clusterqueues"
echo ""
narrate "Users submit to LocalQueues:"
run "kubectl get localqueues -A"
pause

# ============================================================================
section "Step 2: Team A Submits Within Budget"
# ============================================================================

narrate "Team A submits a training job: 2 GPUs."
narrate "Fits within their guaranteed quota — admitted immediately."

run "kubectl apply -f ${DEMO_JOBS_DIR}/team-a-job-low.yaml"
gum spin --title "Waiting for admission..." -- sleep 5

echo ""
gpu_grid "  A·lo" $C_GREEN "  A·lo" $C_GREEN "  idle" $C_DIM "  idle" $C_DIM "  idle" $C_DIM "  idle" $C_DIM "  idle" $C_DIM "  idle" $C_DIM
note "Team A: 2 GPUs (within quota)    Shared: idle    Team B: idle"
echo ""
run "kubectl get workloads -n team-a"
pause

# ============================================================================
section "Step 3: Team A Wants More — Borrowing"
# ============================================================================

narrate "Team A submits an urgent job: 4 more GPUs."
narrate "Quota is full (2/2), so Kueue borrows from the shared pool."

run "kubectl apply -f ${DEMO_JOBS_DIR}/team-a-job-high.yaml"
gum spin --title "Waiting for borrowing..." -- sleep 5

echo ""
gpu_grid "  A·lo" $C_GREEN "  A·lo" $C_GREEN " A·hi★" $C_YELLOW " A·hi★" $C_YELLOW " A·hi★" $C_YELLOW " A·hi★" $C_YELLOW "  idle" $C_DIM "  idle" $C_DIM
note "Team A: 2 guaranteed + 4 borrowed (★)    Team B: idle"
echo ""
run "kubectl get workloads -n team-a"
pause

# ============================================================================
section "Step 4: Team B Arrives — Preemption!"
# ============================================================================

narrate "Team B submits a high-priority job: 4 GPUs."
narrate "Cluster is nearly full. Kueue's preemption policy:"
gum style --foreground $C_RED --padding "0 4" \
  "→ Borrowed resources can be reclaimed" \
  "→ Lower-priority workloads evicted first"

echo ""
narrate "Before:"
gpu_grid "  A·lo" $C_GREEN "  A·lo" $C_GREEN " A·hi★" $C_YELLOW " A·hi★" $C_YELLOW " A·hi★" $C_YELLOW " A·hi★" $C_YELLOW "  idle" $C_DIM "  idle" $C_DIM

narrate "After preemption:"
gpu_grid "  A·lo" $C_GREEN "  A·lo" $C_GREEN " A·hi✗" $C_RED " A·hi✗" $C_RED "  B·hi" $C_BLUE "  B·hi" $C_BLUE "  B·hi" $C_BLUE "  B·hi" $C_BLUE
note "A's borrowed GPUs reclaimed → B admitted"

echo ""
run "kubectl apply -f ${DEMO_JOBS_DIR}/team-b-job-high.yaml"
gum spin --title "Waiting for preemption..." -- sleep 10
pause

# ============================================================================
section "Step 5: The Aftermath"
# ============================================================================

narrate "What survived:"
run "kubectl get workloads -A"

echo ""
gum join --horizontal \
  "$(gum style --border rounded --border-foreground $C_GREEN --foreground $C_GREEN --padding '0 2' '✓ A low-pri' '  2 GPU' '  kept')" \
  "$(gum style --border rounded --border-foreground $C_RED --foreground $C_RED --padding '0 2' '✗ A high-pri' '  4 GPU' '  evicted')" \
  "$(gum style --border rounded --border-foreground $C_BLUE --foreground $C_BLUE --padding '0 2' '✓ B high-pri' '  4 GPU' '  admitted')"

echo ""
gum style --foreground $C_WHITE --bold --padding "0 2" \
  "The guarantee held. Team A kept its 2 nominal GPUs." \
  "Borrowed resources were reclaimed for Team B."
pause

# ============================================================================
section "Clean Up"
# ============================================================================

run "kubectl delete job team-a-job-low -n team-a --ignore-not-found"
run "kubectl delete job team-a-job-high -n team-a --ignore-not-found"
run "kubectl delete job team-b-job-high -n team-b --ignore-not-found"
gum spin --title "Cleaning up..." -- sleep 3

echo ""
title "Demo Complete"

echo ""
gum style --border rounded --border-foreground $C_GREEN --padding "1 3" --width 64 \
  "What we showed:" \
  "" \
  "  1. Guaranteed quotas   — each team's allocation is protected" \
  "  2. Borrowing           — idle capacity used, not wasted" \
  "  3. Preemption          — borrowed GPUs reclaimed on contention" \
  "  4. Priority-aware      — low-priority evicted before high" \
  "" \
  "Beyond this demo:" \
  "  • MIG partitioning  → ./scripts/demo-mig-walkthrough.sh" \
  "  • Add more teams    → just add ClusterQueues + LocalQueues" \
  "  • Coder IDE         → browser-based job submission" \
  "" \
  "Tear down: azd down --force --purge"
