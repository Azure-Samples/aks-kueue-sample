#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# post-provision.sh — Runs after azd provision
# Installs Kueue, Coder, GPU Operator (if MIG), and Kueue configuration
#
# azd passes Bicep outputs as env vars: AZURE_AKS_CLUSTER_NAME, etc.
# ============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
step()  { echo -e "\n${BOLD}${CYAN}==> $1${NC}"; }

# azd sets these from Bicep outputs (camelCase → UPPER_SNAKE via azd convention)
CLUSTER_NAME="${aksClusterName:-aks-ml-demo}"
RESOURCE_GROUP="${AZURE_RESOURCE_GROUP:-rg-aks-ml-demo}"
# MIG_MODE is the single source of truth: none, MIG1g, MIG2g, MIG3g, etc.
# azd stores Bicep outputs as camelCase env vars (e.g. migMode="MIG3g")
MIG_MODE="${migMode:-none}"
if [[ "$MIG_MODE" == "none" ]]; then
  MIG_STRATEGY="none"
else
  MIG_STRATEGY="mixed"
fi
KUEUE_VERSION="0.16.1"

# ============================================================================
# Get AKS credentials
# ============================================================================
step "Getting AKS credentials"

az aks get-credentials \
  --resource-group "$RESOURCE_GROUP" \
  --name "$CLUSTER_NAME" \
  --overwrite-existing \
  --output none

ok "Kubeconfig updated for cluster '${CLUSTER_NAME}'"

info "Waiting for nodes to become Ready..."
kubectl wait --for=condition=Ready node --all --timeout=600s
ok "All nodes ready"

# ============================================================================
# Install GPU software stack
# ============================================================================
if [[ "$MIG_STRATEGY" != "none" ]]; then
  # MIG mode: AKS manages drivers + MIG partitions.
  # Install standalone NVIDIA device plugin with migStrategy for MIG-aware reporting.
  # (GPU Operator is NOT used — it conflicts with AKS-managed MIG drivers)
  step "Installing NVIDIA device plugin (MIG strategy: ${MIG_STRATEGY})"

  helm repo add nvdp https://nvidia.github.io/k8s-device-plugin 2>/dev/null || true
  helm repo update nvdp

  helm upgrade --install nvdp nvdp/nvidia-device-plugin \
    --version=0.17.0 \
    --set migStrategy="$MIG_STRATEGY" \
    --set gfd.enabled=true \
    --set securityContext.privileged=true \
    --namespace nvidia-device-plugin \
    --create-namespace \
    --wait --timeout 120s

  ok "NVIDIA device plugin installed (MIG strategy: ${MIG_STRATEGY})"

else
  # Non-MIG mode: GPU Operator manages drivers + device plugin + toolkit
  step "Installing NVIDIA GPU Operator"

  helm repo add nvidia https://helm.ngc.nvidia.com/nvidia 2>/dev/null || true
  helm repo update nvidia

  helm upgrade --install gpu-operator nvidia/gpu-operator \
    --namespace gpu-operator \
    --create-namespace \
    --set driver.enabled=true \
    --set devicePlugin.enabled=true \
    --set toolkit.enabled=true \
    --set operator.runtimeClass=nvidia-container-runtime \
    --wait --timeout 600s

  ok "GPU Operator installed"
fi

# ============================================================================
# Install Kueue via Helm
# ============================================================================
step "Installing Kueue ${KUEUE_VERSION}"

helm upgrade --install kueue \
  oci://registry.k8s.io/kueue/charts/kueue \
  --version "$KUEUE_VERSION" \
  --namespace kueue-system \
  --create-namespace \
  --wait --timeout 300s

ok "Kueue ${KUEUE_VERSION} installed"

# ============================================================================
# Install Coder via Helm
# ============================================================================
step "Installing Coder v2"

helm repo add coder-v2 https://helm.coder.com/v2 2>/dev/null || true
helm repo update coder-v2

helm upgrade --install coder coder-v2/coder \
  --namespace coder \
  --create-namespace \
  --wait --timeout 300s

ok "Coder v2 installed (embedded DB mode)"

# ============================================================================
# Kueue configuration (namespaces, RBAC, CRs)
# ============================================================================
step "Applying Kueue configuration"

# Create team namespaces
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: team-a
  labels:
    team: "a"
---
apiVersion: v1
kind: Namespace
metadata:
  name: team-b
  labels:
    team: "b"
EOF
info "Namespaces created"

# ServiceAccounts and RBAC for Coder workspaces
for NS in team-a team-b; do
  cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: coder-workspace-sa
  namespace: ${NS}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: coder-workspace-role
  namespace: ${NS}
rules:
  - apiGroups: ["batch"]
    resources: ["jobs"]
    verbs: ["create", "get", "list", "watch", "delete"]
  - apiGroups: ["kueue.x-k8s.io"]
    resources: ["workloads"]
    verbs: ["get", "list", "watch"]
  - apiGroups: [""]
    resources: ["pods", "pods/log"]
    verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: coder-workspace-binding
  namespace: ${NS}
subjects:
  - kind: ServiceAccount
    name: coder-workspace-sa
    namespace: ${NS}
roleRef:
  kind: Role
  name: coder-workspace-role
  apiGroup: rbac.authorization.k8s.io
EOF
done
info "ServiceAccounts and RBAC created"

# Priority Classes
cat <<EOF | kubectl apply -f -
apiVersion: kueue.x-k8s.io/v1beta2
kind: WorkloadPriorityClass
metadata:
  name: high-priority
value: 1000
description: "High priority for urgent training jobs"
---
apiVersion: kueue.x-k8s.io/v1beta2
kind: WorkloadPriorityClass
metadata:
  name: low-priority
value: 100
description: "Low priority for batch/exploratory jobs"
EOF
info "WorkloadPriorityClasses created"

# Kueue CRs based on MIG strategy
if [ "$MIG_STRATEGY" = "none" ]; then
  cat <<EOF | kubectl apply -f -
apiVersion: kueue.x-k8s.io/v1beta2
kind: ResourceFlavor
metadata:
  name: h100-flavor
spec:
  nodeLabels:
    gpu-type: "nvidia-h100"
  tolerations:
    - key: "nvidia.com/gpu"
      operator: "Exists"
      effect: "NoSchedule"
---
apiVersion: kueue.x-k8s.io/v1beta2
kind: Cohort
metadata:
  name: ml-org
---
apiVersion: kueue.x-k8s.io/v1beta2
kind: ClusterQueue
metadata:
  name: team-a-cq
spec:
  cohortName: ml-org
  namespaceSelector:
    matchLabels:
      team: "a"
  preemption:
    withinClusterQueue: LowerPriority
    reclaimWithinCohort: Any
    borrowWithinCohort:
      policy: LowerPriority
  resourceGroups:
    - coveredResources: ["cpu", "memory", "nvidia.com/gpu"]
      flavors:
        - name: h100-flavor
          resources:
            - name: "cpu"
              nominalQuota: 48
            - name: "memory"
              nominalQuota: "512Gi"
            - name: "nvidia.com/gpu"
              nominalQuota: 2
              borrowingLimit: 4
---
apiVersion: kueue.x-k8s.io/v1beta2
kind: ClusterQueue
metadata:
  name: team-b-cq
spec:
  cohortName: ml-org
  namespaceSelector:
    matchLabels:
      team: "b"
  preemption:
    withinClusterQueue: LowerPriority
    reclaimWithinCohort: Any
    borrowWithinCohort:
      policy: LowerPriority
  resourceGroups:
    - coveredResources: ["cpu", "memory", "nvidia.com/gpu"]
      flavors:
        - name: h100-flavor
          resources:
            - name: "cpu"
              nominalQuota: 48
            - name: "memory"
              nominalQuota: "512Gi"
            - name: "nvidia.com/gpu"
              nominalQuota: 2
              borrowingLimit: 4
---
apiVersion: kueue.x-k8s.io/v1beta2
kind: ClusterQueue
metadata:
  name: shared-cq
spec:
  cohortName: ml-org
  namespaceSelector: {}
  resourceGroups:
    - coveredResources: ["cpu", "memory", "nvidia.com/gpu"]
      flavors:
        - name: h100-flavor
          resources:
            - name: "cpu"
              nominalQuota: 96
            - name: "memory"
              nominalQuota: "1024Gi"
            - name: "nvidia.com/gpu"
              nominalQuota: 4
              lendingLimit: 4
EOF
  ok "Kueue config applied (whole GPU mode)"

else
  # Derive MIG resource name from MIG_MODE: MIG3g → nvidia.com/mig-3g.40gb
  # Map: MIG1g→1g.10gb, MIG2g→2g.20gb, MIG3g→3g.40gb, MIG4g→4g.40gb, MIG7g→7g.80gb
  case "$MIG_MODE" in
    MIG1g) MIG_RESOURCE="nvidia.com/mig-1g.10gb"; SLICES_PER_GPU=7 ;;
    MIG2g) MIG_RESOURCE="nvidia.com/mig-2g.20gb"; SLICES_PER_GPU=3 ;;
    MIG3g) MIG_RESOURCE="nvidia.com/mig-3g.40gb"; SLICES_PER_GPU=2 ;;
    MIG4g) MIG_RESOURCE="nvidia.com/mig-4g.40gb"; SLICES_PER_GPU=1 ;;
    MIG7g) MIG_RESOURCE="nvidia.com/mig-7g.80gb"; SLICES_PER_GPU=1 ;;
    *)     error "Unknown MIG_MODE: $MIG_MODE"; exit 1 ;;
  esac
  TOTAL_SLICES=$((8 * SLICES_PER_GPU))
  TEAM_QUOTA=$((TOTAL_SLICES / 4))       # ~25% per team
  SHARED_QUOTA=$((TOTAL_SLICES / 2))     # ~50% shared
  info "MIG resource: ${MIG_RESOURCE}, ${TOTAL_SLICES} total slices, ${TEAM_QUOTA}/team, ${SHARED_QUOTA} shared"

  FLAVOR_NAME="h100-mig-$(echo "$MIG_MODE" | tr '[:upper:]' '[:lower:]')"

  cat <<EOF | kubectl apply -f -
apiVersion: kueue.x-k8s.io/v1beta2
kind: ResourceFlavor
metadata:
  name: ${FLAVOR_NAME}
spec:
  nodeLabels:
    gpu-type: "nvidia-h100"
  tolerations:
    - key: "nvidia.com/gpu"
      operator: "Exists"
      effect: "NoSchedule"
---
apiVersion: kueue.x-k8s.io/v1beta2
kind: Cohort
metadata:
  name: ml-org
---
apiVersion: kueue.x-k8s.io/v1beta2
kind: ClusterQueue
metadata:
  name: team-a-cq
spec:
  cohortName: ml-org
  namespaceSelector:
    matchLabels:
      team: "a"
  preemption:
    withinClusterQueue: LowerPriority
    reclaimWithinCohort: Any
    borrowWithinCohort:
      policy: LowerPriority
  resourceGroups:
    - coveredResources: ["cpu", "memory", "${MIG_RESOURCE}"]
      flavors:
        - name: ${FLAVOR_NAME}
          resources:
            - name: "cpu"
              nominalQuota: 48
            - name: "memory"
              nominalQuota: "512Gi"
            - name: "${MIG_RESOURCE}"
              nominalQuota: ${TEAM_QUOTA}
              borrowingLimit: ${SHARED_QUOTA}
---
apiVersion: kueue.x-k8s.io/v1beta2
kind: ClusterQueue
metadata:
  name: team-b-cq
spec:
  cohortName: ml-org
  namespaceSelector:
    matchLabels:
      team: "b"
  preemption:
    withinClusterQueue: LowerPriority
    reclaimWithinCohort: Any
    borrowWithinCohort:
      policy: LowerPriority
  resourceGroups:
    - coveredResources: ["cpu", "memory", "${MIG_RESOURCE}"]
      flavors:
        - name: ${FLAVOR_NAME}
          resources:
            - name: "cpu"
              nominalQuota: 48
            - name: "memory"
              nominalQuota: "512Gi"
            - name: "${MIG_RESOURCE}"
              nominalQuota: ${TEAM_QUOTA}
              borrowingLimit: ${SHARED_QUOTA}
---
apiVersion: kueue.x-k8s.io/v1beta2
kind: ClusterQueue
metadata:
  name: shared-cq
spec:
  cohortName: ml-org
  namespaceSelector: {}
  resourceGroups:
    - coveredResources: ["cpu", "memory", "${MIG_RESOURCE}"]
      flavors:
        - name: ${FLAVOR_NAME}
          resources:
            - name: "cpu"
              nominalQuota: 96
            - name: "memory"
              nominalQuota: "1024Gi"
            - name: "${MIG_RESOURCE}"
              nominalQuota: ${SHARED_QUOTA}
              lendingLimit: ${SHARED_QUOTA}
EOF
  ok "Kueue config applied (MIG mode: ${MIG_MODE}, resource: ${MIG_RESOURCE})"
fi

# LocalQueues (same for both modes)
cat <<EOF | kubectl apply -f -
apiVersion: kueue.x-k8s.io/v1beta2
kind: LocalQueue
metadata:
  name: team-a-lq
  namespace: team-a
spec:
  clusterQueue: team-a-cq
---
apiVersion: kueue.x-k8s.io/v1beta2
kind: LocalQueue
metadata:
  name: team-b-lq
  namespace: team-b
spec:
  clusterQueue: team-b-cq
EOF
ok "LocalQueues created"

# ============================================================================
# Verify
# ============================================================================
step "Verifying cluster"

echo ""
info "Nodes:"
kubectl get nodes -o wide
echo ""

info "GPU resources:"
kubectl get nodes -o json | \
  jq -r '.items[] | select(.status.allocatable["nvidia.com/gpu"] != null) | "\(.metadata.name): \(.status.allocatable["nvidia.com/gpu"]) GPUs"' \
  2>/dev/null || warn "GPU nodes may still be provisioning"
echo ""

info "Kueue ClusterQueues:"
kubectl get clusterqueues 2>/dev/null || true
echo ""

info "Kueue LocalQueues:"
kubectl get localqueues -A 2>/dev/null || true
echo ""

CODER_URL=$(kubectl get svc -n coder -o jsonpath='{.items[0].status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
if [[ -n "$CODER_URL" ]]; then
  ok "Coder URL: http://${CODER_URL}"
else
  warn "Coder LoadBalancer IP not yet assigned. Check: kubectl get svc -n coder"
fi

echo ""
ok "Post-provision complete! Run scripts/demo-walkthrough.sh to start the demo."
