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
# MIG_MODE: none, MIG1g, MIG2g, MIG3g, etc.
# azd stores Bicep outputs as camelCase env vars (e.g. migMode="MIG3g")
MIG_MODE="${migMode:-none}"
GPU_VM_SIZE="${gpuVmSize:-Standard_ND96isr_H100_v5}"
KUEUE_VERSION="0.16.4"
ENABLE_MONITORING="${enableMonitoring:-false}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Derive GPU count from VM SKU
case "$GPU_VM_SIZE" in
  Standard_ND96isr_H100_v5)   GPUS_PER_NODE=8 ;;
  Standard_NC80adis_H100_v5)  GPUS_PER_NODE=2 ;;
  Standard_NC40ads_H100_v5)   GPUS_PER_NODE=1 ;;
  *)
    echo "ERROR: Unsupported GPU VM size: $GPU_VM_SIZE"
    echo "Supported: Standard_ND96isr_H100_v5, Standard_NC80adis_H100_v5, Standard_NC40ads_H100_v5"
    exit 1 ;;
esac

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
# Install NVIDIA GPU Operator (always — manages drivers, device plugin, DCGM)
# Follows: https://techcommunity.microsoft.com/blog/azure-ai-foundry-blog/deploying-azure-nd-h100-v5-instances-in-aks-with-nvidia-mig-gpu-slicing/4384080
# ============================================================================
step "Installing NVIDIA GPU Operator"

helm repo add nvidia https://helm.ngc.nvidia.com/nvidia 2>/dev/null || true
helm repo update nvidia

GPU_OPERATOR_ARGS=(
  --namespace gpu-operator
  --create-namespace
  --set operator.runtimeClass=nvidia-container-runtime
)

# MIG: enable MIG Manager + set device plugin strategy
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

# ============================================================================
# Configure MIG via node labels (GPU Operator MIG Manager handles partitioning)
# ============================================================================
if [[ "$MIG_MODE" != "none" ]]; then
  # Map migMode to the mig-parted config label
  # H100 NVL (NC-series, 94GB) uses different profile sizes than H100 SXM5 (ND-series, 80GB)
  if [[ "$GPU_VM_SIZE" == Standard_NC* ]]; then
    case "$MIG_MODE" in
      MIG1g) MIG_CONFIG="all-1g.12gb" ;;
      MIG2g) MIG_CONFIG="all-2g.24gb" ;;
      MIG3g) MIG_CONFIG="all-3g.47gb" ;;
      MIG4g) MIG_CONFIG="all-4g.47gb" ;;
      MIG7g) MIG_CONFIG="all-7g.94gb" ;;
      *)     error "Unknown MIG_MODE: $MIG_MODE"; exit 1 ;;
    esac
  else
    case "$MIG_MODE" in
      MIG1g) MIG_CONFIG="all-1g.10gb" ;;
      MIG2g) MIG_CONFIG="all-2g.20gb" ;;
      MIG3g) MIG_CONFIG="all-3g.40gb" ;;
      MIG4g) MIG_CONFIG="all-4g.40gb" ;;
      MIG7g) MIG_CONFIG="all-7g.80gb" ;;
      *)     error "Unknown MIG_MODE: $MIG_MODE"; exit 1 ;;
    esac
  fi

  step "Configuring MIG: ${MIG_CONFIG}"

  for node in $(kubectl get nodes -l gpu-type=nvidia-h100 -o jsonpath='{.items[*].metadata.name}'); do
    info "Labeling $node with nvidia.com/mig.config=${MIG_CONFIG}"
    kubectl label node "$node" nvidia.com/mig.config="$MIG_CONFIG" --overwrite
  done

  info "Waiting for MIG Manager to partition GPUs (nodes may briefly go NotReady)..."
  sleep 60
  kubectl wait --for=condition=Ready node -l gpu-type=nvidia-h100 --timeout=300s
  ok "MIG configured: ${MIG_CONFIG}"

  # Verify MIG slices are visible
  info "Checking MIG resources on nodes..."
  kubectl get nodes -o json | jq -r '
    .items[] |
    select(.status.allocatable | keys[] | startswith("nvidia.com/mig")) |
    "\(.metadata.name): \(.status.allocatable | with_entries(select(.key | startswith("nvidia.com/mig"))))"'
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
  --values "${SCRIPT_DIR}/../coder/values.yaml" \
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

# Kueue CRs based on MIG mode
# Compute GPU quotas dynamically from GPUs per node
TOTAL_GPUS=$((1 * GPUS_PER_NODE))  # gpuNodeCount=1 by default

if [[ $TOTAL_GPUS -lt 4 ]]; then
  warn "Only ${TOTAL_GPUS} GPU(s) available. Kueue demo features (borrowing, preemption)"
  warn "require 4+ GPUs. Quotas will be set for basic scheduling only."
fi

# Quota logic by GPU count:
#   1 GPU:  team-a=1, team-b=0, shared=0 (single-team mode)
#   2 GPUs: team-a=1, team-b=1, shared=0 (no sharing)
#   4 GPUs: team-a=1, team-b=1, shared=2
#   8 GPUs: team-a=2, team-b=2, shared=4 (default ND-series)
if [[ $TOTAL_GPUS -ge 8 ]]; then
  TEAM_A_GPU_QUOTA=$((TOTAL_GPUS / 4))
  TEAM_B_GPU_QUOTA=$((TOTAL_GPUS / 4))
  SHARED_GPU_QUOTA=$((TOTAL_GPUS / 2))
elif [[ $TOTAL_GPUS -ge 4 ]]; then
  TEAM_A_GPU_QUOTA=1
  TEAM_B_GPU_QUOTA=1
  SHARED_GPU_QUOTA=$((TOTAL_GPUS - 2))
elif [[ $TOTAL_GPUS -ge 2 ]]; then
  TEAM_A_GPU_QUOTA=1
  TEAM_B_GPU_QUOTA=1
  SHARED_GPU_QUOTA=0
else
  TEAM_A_GPU_QUOTA=1
  TEAM_B_GPU_QUOTA=0
  SHARED_GPU_QUOTA=0
fi
TEAM_A_BORROW_LIMIT=$SHARED_GPU_QUOTA
TEAM_B_BORROW_LIMIT=$SHARED_GPU_QUOTA
info "GPU quotas: ${TOTAL_GPUS} total, team-a=${TEAM_A_GPU_QUOTA}, team-b=${TEAM_B_GPU_QUOTA}, shared=${SHARED_GPU_QUOTA}"

if [ "$MIG_MODE" = "none" ]; then
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
              nominalQuota: ${TEAM_A_GPU_QUOTA}
              borrowingLimit: ${TEAM_A_BORROW_LIMIT}
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
              nominalQuota: ${TEAM_B_GPU_QUOTA}
              borrowingLimit: ${TEAM_B_BORROW_LIMIT}
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
              nominalQuota: ${SHARED_GPU_QUOTA}
              lendingLimit: ${SHARED_GPU_QUOTA}
EOF
  ok "Kueue config applied (whole GPU mode)"

else
  # Derive MIG resource name from MIG_MODE and GPU variant
  # H100 SXM5 (ND-series) has 80GB → profiles: 1g.10gb, 2g.20gb, 3g.40gb, 4g.40gb, 7g.80gb
  # H100 NVL  (NC-series) has 94GB → profiles: 1g.12gb, 2g.24gb, 3g.47gb, 4g.47gb, 7g.94gb
  IS_NC_SERIES=false
  [[ "$GPU_VM_SIZE" == Standard_NC* ]] && IS_NC_SERIES=true

  if [[ "$IS_NC_SERIES" == "true" ]]; then
    case "$MIG_MODE" in
      MIG1g) MIG_RESOURCE="nvidia.com/mig-1g.12gb"; SLICES_PER_GPU=7 ;;
      MIG2g) MIG_RESOURCE="nvidia.com/mig-2g.24gb"; SLICES_PER_GPU=3 ;;
      MIG3g) MIG_RESOURCE="nvidia.com/mig-3g.47gb"; SLICES_PER_GPU=2 ;;
      MIG4g) MIG_RESOURCE="nvidia.com/mig-4g.47gb"; SLICES_PER_GPU=1 ;;
      MIG7g) MIG_RESOURCE="nvidia.com/mig-7g.94gb"; SLICES_PER_GPU=1 ;;
      *)     error "Unknown MIG_MODE: $MIG_MODE"; exit 1 ;;
    esac
  else
    case "$MIG_MODE" in
      MIG1g) MIG_RESOURCE="nvidia.com/mig-1g.10gb"; SLICES_PER_GPU=7 ;;
      MIG2g) MIG_RESOURCE="nvidia.com/mig-2g.20gb"; SLICES_PER_GPU=3 ;;
      MIG3g) MIG_RESOURCE="nvidia.com/mig-3g.40gb"; SLICES_PER_GPU=2 ;;
      MIG4g) MIG_RESOURCE="nvidia.com/mig-4g.40gb"; SLICES_PER_GPU=1 ;;
      MIG7g) MIG_RESOURCE="nvidia.com/mig-7g.80gb"; SLICES_PER_GPU=1 ;;
      *)     error "Unknown MIG_MODE: $MIG_MODE"; exit 1 ;;
    esac
  fi
  TOTAL_SLICES=$((GPUS_PER_NODE * SLICES_PER_GPU))
  TEAM_QUOTA=$((TOTAL_SLICES / 4))       # ~25% per team
  [[ "$TEAM_QUOTA" -lt 1 ]] && TEAM_QUOTA=1  # ensure at least 1 slice per team
  SHARED_QUOTA=$((TOTAL_SLICES / 2))     # ~50% shared
  [[ "$SHARED_QUOTA" -lt 1 ]] && SHARED_QUOTA=1
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
# Deploy monitoring stack (optional — enabled via enableMonitoring=true)
# Installs Prometheus + Grafana, enables DCGM + Kueue ServiceMonitors
# ============================================================================
if [[ "$ENABLE_MONITORING" == "true" ]]; then
  step "Deploy monitoring stack (Prometheus + Grafana)"

  helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
  helm repo update prometheus-community

  # 1. Install kube-prometheus-stack (must come first — provides ServiceMonitor CRDs)
  PROM_STACK_VERSION="72.6.2"
  helm upgrade --install prometheus \
    prometheus-community/kube-prometheus-stack \
    --version "$PROM_STACK_VERSION" \
    --namespace monitoring \
    --create-namespace \
    --values "${PROJECT_DIR}/monitoring/values-prometheus-stack.yaml" \
    --wait --timeout 300s
  ok "kube-prometheus-stack ${PROM_STACK_VERSION} installed"

  # 2. Upgrade GPU Operator to enable DCGM exporter ServiceMonitor
  helm upgrade gpu-operator nvidia/gpu-operator \
    --namespace gpu-operator \
    --reuse-values \
    -f "${PROJECT_DIR}/monitoring/values-gpu-operator-monitoring.yaml" \
    --wait --timeout 300s
  ok "GPU Operator upgraded with DCGM ServiceMonitor"

  # 3. Upgrade Kueue to enable Prometheus ServiceMonitor
  helm upgrade kueue \
    oci://registry.k8s.io/kueue/charts/kueue \
    --version "$KUEUE_VERSION" \
    --namespace kueue-system \
    --reuse-values \
    --set enablePrometheus=true \
    --wait --timeout 300s
  ok "Kueue upgraded with Prometheus ServiceMonitor"

  # 4. Create Grafana dashboard ConfigMaps from JSON files
  kubectl create configmap gpu-cluster-overview-dashboard \
    --from-file=gpu-cluster-overview.json="${PROJECT_DIR}/monitoring/dashboards/gpu-cluster-overview.json" \
    --namespace monitoring \
    --dry-run=client -o yaml | kubectl apply -f -
  kubectl label configmap gpu-cluster-overview-dashboard \
    -n monitoring grafana_dashboard=1 --overwrite
  kubectl annotate configmap gpu-cluster-overview-dashboard \
    -n monitoring grafana_folder="GPU Observability" --overwrite

  kubectl create configmap dcgm-exporter-dashboard \
    --from-file=dcgm-exporter-dashboard.json="${PROJECT_DIR}/monitoring/dashboards/dcgm-exporter-dashboard.json" \
    --namespace monitoring \
    --dry-run=client -o yaml | kubectl apply -f -
  kubectl label configmap dcgm-exporter-dashboard \
    -n monitoring grafana_dashboard=1 --overwrite
  kubectl annotate configmap dcgm-exporter-dashboard \
    -n monitoring grafana_folder="GPU Observability" --overwrite

  ok "Grafana dashboards provisioned"

  # 5. Wait for Prometheus and Grafana to be ready
  info "Waiting for monitoring pods..."
  kubectl wait --for=condition=Ready pod \
    -l app.kubernetes.io/name=grafana \
    -n monitoring --timeout=120s 2>/dev/null || warn "Grafana pod not ready yet"
  kubectl wait --for=condition=Ready pod \
    -l app.kubernetes.io/name=prometheus \
    -n monitoring --timeout=120s 2>/dev/null || warn "Prometheus pod not ready yet"

  ok "Monitoring stack deployed"
  info "Access Grafana: kubectl port-forward -n monitoring svc/prometheus-grafana 3000:80"
  info "Login: admin / demo"
fi

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
