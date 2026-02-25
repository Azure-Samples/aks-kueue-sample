#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# demo-mig-walkthrough.sh — MIG GPU partitioning demo
# Auto-detects MIG profile. Requires: gum, kubectl, jq
# ============================================================================

if ! command -v gum &>/dev/null; then
  echo "ERROR: gum is required. Install with: brew install gum"
  exit 1
fi

# --- Theme colors ---
C_GREEN=76
C_BLUE=39
C_RED=196
C_CYAN=87
C_DIM=243
C_WHITE=255

# --- Helpers ---
title()   { echo ""; gum style --border double --border-foreground $C_CYAN --foreground $C_CYAN --bold --padding "1 3" --width 64 --align center "$@"; }
section() { echo ""; gum style --border rounded --border-foreground $C_CYAN --foreground $C_WHITE --bold --padding "0 2" --width 64 "$@"; }
narrate() { gum style --foreground 220 --padding "0 2" "$@"; }
note()    { gum style --foreground $C_DIM --padding "0 2" "$@"; }
run()     { gum style --foreground $C_DIM --padding "0 2" "$ $*"; eval "$@"; }
pause()   { echo ""; gum confirm --default=Yes --affirmative "Continue →" --negative "" 2>/dev/null || true; }

mig_box() {
  local label="$1" color="$2"
  gum style --border rounded --border-foreground "$color" --foreground "$color" --padding "0 1" --width 10 "$label"
}

# ============================================================================
# Detect MIG profile
# ============================================================================
MIG_RESOURCE=$(kubectl get nodes -o json | jq -r '
  [.items[].status.allocatable | keys[] | select(startswith("nvidia.com/mig"))] | first // empty')

if [[ -z "$MIG_RESOURCE" ]]; then
  gum style --foreground $C_RED --bold --padding "1 2" \
    "ERROR: No MIG resources found." \
    "Deploy with: azd env set migMode MIG3g && azd up"
  exit 1
fi

MIG_TOTAL=$(kubectl get nodes -o json | jq -r "
  [.items[].status.allocatable[\"$MIG_RESOURCE\"] // \"0\" | tonumber] | add")
MIG_SLICE=$(echo "$MIG_RESOURCE" | sed 's|nvidia.com/mig-||')

# ============================================================================
title "GPU Slicing with MIG" "Hardware Isolation on a Single GPU"
# ============================================================================

echo ""
narrate "A whole H100 has 80GB — but many jobs need far less."
narrate "MIG splits one GPU into isolated partitions."
narrate "Each gets its own compute, memory, and cache."

echo ""
gum style --border rounded --border-foreground $C_RED --foreground $C_RED --padding "1 3" --width 60 \
  "Without MIG:" \
  "" \
  "  ┌─────────────────────────────────┐" \
  "  │  Your job uses 30GB             │" \
  "  │               50GB wasted →     │" \
  "  └─────────────────────────────────┘" \
  "  One job per GPU. Expensive waste."

echo ""
gum style --border rounded --border-foreground $C_GREEN --foreground $C_GREEN --padding "1 3" --width 60 \
  "With MIG ($MIG_SLICE):" \
  "" \
  "  ┌───────────────┬───────────────┐" \
  "  │   Team A      │   Team B      │" \
  "  │   $MIG_SLICE     │   $MIG_SLICE     │" \
  "  │   own SMs     │   own SMs     │" \
  "  │   own cache   │   own cache   │" \
  "  └───────────────┴───────────────┘" \
  "  2x utilization. Zero interference."

echo ""
note "Detected: ${MIG_TOTAL}x $MIG_SLICE slices  ($MIG_RESOURCE)"
pause

# ============================================================================
section "Step 1: What the Cluster Sees"
# ============================================================================

narrate "Each H100 is partitioned. The node advertises"
narrate "${MIG_TOTAL} schedulable MIG slices instead of 8 whole GPUs."
echo ""
run "kubectl get nodes -o json | jq -r '.items[] | select(.status.allocatable[\"${MIG_RESOURCE}\"] != null) | \"\(.metadata.name): \(.status.allocatable[\"${MIG_RESOURCE}\"]) x ${MIG_SLICE}\"'"
pause

narrate "Kueue quotas — same structure, different resource name:"
run "kubectl get clusterqueues"
echo ""
run "kubectl get resourceflavors"
pause

# ============================================================================
section "Step 2: Team A Takes a Slice"
# ============================================================================

narrate "Team A submits a job requesting 1x $MIG_SLICE."
narrate "Kueue checks quota and admits."

cat <<EOF | kubectl apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: team-a-mig-job
  namespace: team-a
  labels:
    kueue.x-k8s.io/queue-name: team-a-lq
    kueue.x-k8s.io/priority-class: low-priority
spec:
  completions: 1
  parallelism: 1
  template:
    metadata:
      labels:
        app: team-a-mig-job
    spec:
      restartPolicy: Never
      tolerations:
        - key: nvidia.com/gpu
          operator: Exists
          effect: NoSchedule
      containers:
        - name: gpu-workload
          image: nvidia/cuda:12.4.0-base-ubuntu22.04
          command: ["bash", "-c", "nvidia-smi -L && sleep 300"]
          resources:
            requests:
              ${MIG_RESOURCE}: 1
            limits:
              ${MIG_RESOURCE}: 1
EOF

gum spin --title "Waiting for admission..." -- sleep 5

echo ""
gum join --horizontal \
  "$(mig_box "Team A" $C_GREEN)" \
  "$(mig_box " idle " $C_DIM)" \
  "$(mig_box " idle " $C_DIM)" \
  "$(mig_box " idle " $C_DIM)"
note "GPU 0: 1 of 2 slices used"
echo ""
run "kubectl get workloads -n team-a"
pause

# ============================================================================
section "Step 3: Team B — Concurrent on the Same Node"
# ============================================================================

narrate "Team B submits a job for 1x $MIG_SLICE."
narrate "Both teams on the same node — each in its own hardware-isolated MIG partition."

cat <<EOF | kubectl apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: team-b-mig-job
  namespace: team-b
  labels:
    kueue.x-k8s.io/queue-name: team-b-lq
    kueue.x-k8s.io/priority-class: low-priority
spec:
  completions: 1
  parallelism: 1
  template:
    metadata:
      labels:
        app: team-b-mig-job
    spec:
      restartPolicy: Never
      tolerations:
        - key: nvidia.com/gpu
          operator: Exists
          effect: NoSchedule
      containers:
        - name: gpu-workload
          image: nvidia/cuda:12.4.0-base-ubuntu22.04
          command: ["bash", "-c", "nvidia-smi -L && sleep 300"]
          resources:
            requests:
              ${MIG_RESOURCE}: 1
            limits:
              ${MIG_RESOURCE}: 1
EOF

gum spin --title "Waiting for admission..." -- sleep 5

echo ""
gum join --horizontal \
  "$(mig_box "Team A" $C_GREEN)" \
  "$(mig_box "Team B" $C_BLUE)" \
  "$(mig_box " idle " $C_DIM)" \
  "$(mig_box " idle " $C_DIM)"
note "Same node, isolated MIG partitions — may be same or different GPUs"
echo ""
run "kubectl get workloads -A"
run "kubectl get pods -A -l 'app in (team-a-mig-job, team-b-mig-job)' -o wide"
pause

# ============================================================================
section "Step 4: Proof of Isolation"
# ============================================================================

narrate "Each pod sees only its own MIG device."
narrate "Different UUIDs = different hardware partitions."

TEAM_A_POD=$(kubectl get pods -n team-a -l app=team-a-mig-job -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
TEAM_B_POD=$(kubectl get pods -n team-b -l app=team-b-mig-job -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

echo ""
if [[ -n "$TEAM_A_POD" ]]; then
  gum style --foreground $C_GREEN --bold --padding "0 2" "Team A's nvidia-smi:"
  run "kubectl exec -n team-a $TEAM_A_POD -- nvidia-smi -L 2>/dev/null || echo '  (not ready)'"
fi
echo ""
if [[ -n "$TEAM_B_POD" ]]; then
  gum style --foreground $C_BLUE --bold --padding "0 2" "Team B's nvidia-smi:"
  run "kubectl exec -n team-b $TEAM_B_POD -- nvidia-smi -L 2>/dev/null || echo '  (not ready)'"
fi

echo ""
gum style --border rounded --border-foreground $C_CYAN --padding "1 3" --width 56 \
  "Different UUIDs = different partitions" \
  "Neither can access the other's memory" \
  "Performance is guaranteed by hardware"
pause

# ============================================================================
section "Clean Up"
# ============================================================================

run "kubectl delete job team-a-mig-job -n team-a --ignore-not-found"
run "kubectl delete job team-b-mig-job -n team-b --ignore-not-found"
gum spin --title "Cleaning up..." -- sleep 3

echo ""
title "MIG Demo Complete"

echo ""
gum style --border rounded --border-foreground $C_GREEN --padding "1 3" --width 64 \
  "What we showed:" \
  "" \
  "  1. GPU slicing    — one H100 → multiple $MIG_SLICE partitions" \
  "  2. Zero waste     — jobs use only what they need" \
  "  3. Isolation      — each team sees only its MIG device" \
  "  4. Kueue          — MIG slices as first-class resources" \
  "" \
  "The math:" \
  "  Without MIG: 8 GPUs → 8 concurrent jobs" \
  "  With MIG:    ${MIG_TOTAL} slices → ${MIG_TOTAL} concurrent jobs" \
  "" \
  "Tear down: azd down --force --purge"
