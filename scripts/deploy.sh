#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# deploy.sh — One-command deploy for AKS ML Cluster with Kueue & Coder
#
# Strategy:
#   1. Bicep deploys Azure infra (AKS cluster + GPU node pool)
#   2. Local helm/kubectl installs Kueue, Coder, GPU Operator, and Kueue CRs
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
step()  { echo -e "\n${BOLD}${CYAN}==> Step $1: $2${NC}"; }

# Defaults
RESOURCE_GROUP="rg-aks-ml-demo"
LOCATION="southafricanorth"
CLUSTER_NAME="aks-ml-demo"
MIG_MODE="none"
KUEUE_VERSION="0.16.1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

while [[ $# -gt 0 ]]; do
  case $1 in
    --resource-group) RESOURCE_GROUP="$2"; shift 2 ;;
    --location)       LOCATION="$2"; shift 2 ;;
    --cluster-name)   CLUSTER_NAME="$2"; shift 2 ;;
    --mig-mode)       MIG_MODE="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: $0 [OPTIONS]"
      echo ""
      echo "Options:"
      echo "  --resource-group  NAME   Resource group name (default: rg-aks-ml-demo)"
      echo "  --location        REGION Azure region (default: southafricanorth)"
      echo "  --cluster-name    NAME   AKS cluster name (default: aks-ml-demo)"
      echo "  --mig-mode        MODE   MIG mode: none|MIG1g|MIG2g|MIG3g|MIG7g (default: none)"
      echo "  -h, --help               Show this help"
      exit 0
      ;;
    *) error "Unknown option: $1"; exit 1 ;;
  esac
done

# ============================================================================
# Cost Warning
# ============================================================================
echo ""
echo -e "${RED}${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${RED}${BOLD}║  ⚠️  COST WARNING                                          ║${NC}"
echo -e "${RED}${BOLD}║                                                              ║${NC}"
echo -e "${RED}${BOLD}║  This deployment creates a Standard_ND96isr_H100_v5 node    ║${NC}"
echo -e "${RED}${BOLD}║  which costs approximately \$98/hr (~\$2,360/day).            ║${NC}"
echo -e "${RED}${BOLD}║                                                              ║${NC}"
echo -e "${RED}${BOLD}║  Remember to run teardown.sh when done!                      ║${NC}"
echo -e "${RED}${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""

read -r -p "Do you want to continue? (y/N) " response
if [[ ! "$response" =~ ^[Yy]$ ]]; then
  info "Deployment cancelled."
  exit 0
fi

# ============================================================================
# Step 0: Pre-flight checks
# ============================================================================
step 0 "Pre-flight checks"

for cmd in az kubectl helm; do
  if ! command -v "$cmd" &>/dev/null; then
    error "'$cmd' is required but not installed."
    exit 1
  fi
done
ok "Required CLI tools found (az, kubectl, helm)"

if ! az account show &>/dev/null; then
  error "Not logged in to Azure. Run 'az login' first."
  exit 1
fi

SUBSCRIPTION=$(az account show --query name -o tsv)
info "Using subscription: ${BOLD}${SUBSCRIPTION}${NC}"

# ============================================================================
# Step 1: Create resource group
# ============================================================================
step 1 "Create resource group '${RESOURCE_GROUP}' in '${LOCATION}'"

if az group show --name "$RESOURCE_GROUP" &>/dev/null; then
  warn "Resource group '${RESOURCE_GROUP}' already exists, reusing."
else
  az group create --name "$RESOURCE_GROUP" --location "$LOCATION" --output none
  ok "Resource group created"
fi

# ============================================================================
# Step 2: Deploy Bicep (AKS cluster + GPU node pool only)
# ============================================================================
step 2 "Deploy AKS cluster + GPU node pool via Bicep (10-20 minutes)"

BICEP_FILE="${PROJECT_DIR}/infra/main.bicep"
if [[ ! -f "$BICEP_FILE" ]]; then
  error "Bicep file not found: $BICEP_FILE"
  exit 1
fi

info "MIG mode: ${BOLD}${MIG_MODE}${NC}"
info "Starting Bicep deployment..."

az deployment group create \
  --resource-group "$RESOURCE_GROUP" \
  --template-file "$BICEP_FILE" \
  --parameters \
    clusterName="$CLUSTER_NAME" \
    location="$LOCATION" \
  --output none

ok "AKS cluster and GPU node pool deployed"

# ============================================================================
# Step 3: Get AKS credentials
# ============================================================================
step 3 "Get AKS credentials"

az aks get-credentials \
  --resource-group "$RESOURCE_GROUP" \
  --name "$CLUSTER_NAME" \
  --overwrite-existing \
  --output none

ok "Kubeconfig updated for cluster '${CLUSTER_NAME}'"

# Wait for nodes to be ready
info "Waiting for nodes to become Ready..."
kubectl wait --for=condition=Ready node --all --timeout=600s
ok "All nodes ready"

# ============================================================================
# Step 4: Install NVIDIA GPU Operator
# ============================================================================
step 4 "Install NVIDIA GPU Operator"

helm repo add nvidia https://helm.ngc.nvidia.com/nvidia 2>/dev/null || true
helm repo update nvidia

GPU_OPERATOR_ARGS=(
  --namespace gpu-operator
  --create-namespace
  --set operator.runtimeClass=nvidia-container-runtime
)

if [[ "$MIG_MODE" != "none" ]]; then
  GPU_OPERATOR_ARGS+=(
    --set mig.strategy=mixed
    --set migManager.enabled=true
  )
fi

helm upgrade --install gpu-operator nvidia/gpu-operator \
  "${GPU_OPERATOR_ARGS[@]}" \
  --wait --timeout 600s

ok "GPU Operator installed"

# Configure MIG if enabled
if [[ "$MIG_MODE" != "none" ]]; then
  case "$MIG_MODE" in
    MIG1g) MIG_CONFIG="all-1g.10gb" ;;
    MIG2g) MIG_CONFIG="all-2g.20gb" ;;
    MIG3g) MIG_CONFIG="all-3g.40gb" ;;
    MIG4g) MIG_CONFIG="all-4g.40gb" ;;
    MIG7g) MIG_CONFIG="all-7g.80gb" ;;
    *)     error "Unknown MIG mode: $MIG_MODE"; exit 1 ;;
  esac

  step "4b" "Configure MIG: ${MIG_CONFIG}"
  for node in $(kubectl get nodes -l gpu-type=nvidia-h100 -o jsonpath='{.items[*].metadata.name}'); do
    kubectl label node "$node" nvidia.com/mig.config="$MIG_CONFIG" --overwrite
  done
  info "Waiting for MIG Manager to partition GPUs..."
  sleep 60
  kubectl wait --for=condition=Ready node -l gpu-type=nvidia-h100 --timeout=300s
  ok "MIG configured: ${MIG_CONFIG}"
fi

# ============================================================================
# Step 5: Install Kueue via Helm
# ============================================================================
step 5 "Install Kueue ${KUEUE_VERSION} via Helm"

helm upgrade --install kueue \
  oci://registry.k8s.io/kueue/charts/kueue \
  --version "$KUEUE_VERSION" \
  --namespace kueue-system \
  --create-namespace \
  --wait --timeout 300s

ok "Kueue ${KUEUE_VERSION} installed"

# ============================================================================
# Step 6: Install Coder via Helm
# ============================================================================
step 6 "Install Coder v2 via Helm"

helm repo add coder-v2 https://helm.coder.com/v2 2>/dev/null || true
helm repo update coder-v2

helm upgrade --install coder coder-v2/coder \
  --namespace coder \
  --create-namespace \
  --wait --timeout 300s

ok "Coder v2 installed (embedded DB mode)"

# ============================================================================
# Step 7: Apply Kueue configuration (namespaces, RBAC, CRs)
# ============================================================================
step 7 "Apply Kueue configuration"

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

# Apply Kueue CRs based on MIG mode
if [ "$MIG_MODE" = "none" ]; then
  # Whole GPU mode
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
  # MIG mode — dynamic based on MIG_MODE
  case "$MIG_MODE" in
    MIG1g) MIG_RESOURCE="nvidia.com/mig-1g.10gb"; SLICES_PER_GPU=7 ;;
    MIG2g) MIG_RESOURCE="nvidia.com/mig-2g.20gb"; SLICES_PER_GPU=3 ;;
    MIG3g) MIG_RESOURCE="nvidia.com/mig-3g.40gb"; SLICES_PER_GPU=2 ;;
    MIG4g) MIG_RESOURCE="nvidia.com/mig-4g.40gb"; SLICES_PER_GPU=1 ;;
    MIG7g) MIG_RESOURCE="nvidia.com/mig-7g.80gb"; SLICES_PER_GPU=1 ;;
    *)     error "Unknown MIG_MODE: $MIG_MODE"; exit 1 ;;
  esac
  TOTAL_SLICES=$((8 * SLICES_PER_GPU))
  TEAM_QUOTA=$((TOTAL_SLICES / 4))
  SHARED_QUOTA=$((TOTAL_SLICES / 2))
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
# Step 8: Verify cluster
# ============================================================================
step 8 "Verify cluster health"

info "Nodes:"
kubectl get nodes -o wide
echo ""

info "GPU resources:"
kubectl get nodes -o json | \
  jq -r '.items[] | select(.status.allocatable["nvidia.com/gpu"] != null) | "\(.metadata.name): \(.status.allocatable["nvidia.com/gpu"]) GPUs"' \
  2>/dev/null || warn "No GPU nodes ready yet (may still be provisioning)"
echo ""

info "Kueue ClusterQueues:"
kubectl get clusterqueues 2>/dev/null || warn "ClusterQueues not yet available"
echo ""

info "Kueue LocalQueues:"
kubectl get localqueues -A 2>/dev/null || warn "LocalQueues not yet available"
echo ""

# ============================================================================
# Access Info
# ============================================================================
step 9 "Access information"

CODER_URL=$(kubectl get svc -n coder -o jsonpath='{.items[0].status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
if [[ -n "$CODER_URL" ]]; then
  ok "Coder URL: ${BOLD}http://${CODER_URL}${NC}"
else
  warn "Coder LoadBalancer IP not yet assigned. Check with:"
  echo "  kubectl get svc -n coder"
fi

echo ""
echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}${BOLD}║  ✅ Deployment complete!                                     ║${NC}"
echo -e "${GREEN}${BOLD}║                                                              ║${NC}"
echo -e "${GREEN}${BOLD}║  Next steps:                                                 ║${NC}"
echo -e "${GREEN}${BOLD}║    1. Run: scripts/demo-walkthrough.sh                       ║${NC}"
echo -e "${GREEN}${BOLD}║    2. When done: scripts/teardown.sh                         ║${NC}"
echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
