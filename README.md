# AKS ML Cluster with Kueue Multitenancy & Coder IDE

A sample AKS deployment with NVIDIA H100 GPUs, [Kueue](https://kueue.sigs.k8s.io/) for multitenant GPU scheduling, and [Coder v2](https://coder.com/) as a browser-based development environment.

**What it demonstrates:**

- **Fair-sharing** — guaranteed GPU quotas per team with burst borrowing
- **Preemption** — high-priority jobs reclaim borrowed resources automatically
- **MIG partitioning** (optional) — split H100s into isolated GPU instances
- **Coder IDE** — submit GPU jobs from a browser-based VS Code workspace

## Architecture

The cluster runs two node pools. The system pool hosts Kueue and Coder. The GPU pool runs ND-series H100 VMs managed by the NVIDIA GPU Operator. Kueue enforces per-team quotas through three ClusterQueues in a shared Cohort, enabling borrowing and preemption across teams.

```
AKS Cluster
├── System Pool ─── Kueue controller, Coder v2, GPU Operator
└── GPU Pool ────── Kueue-managed workloads
                    ├── team-a namespace ◄── team-a-cq (guaranteed quota)
                    ├── team-b namespace ◄── team-b-cq (guaranteed quota)
                    └── shared pool      ◄── shared-cq (burst capacity)
                    Cohort "ml-org" enables borrowing/lending across all queues
```

## Prerequisites

| Tool | Version |
|---|---|
| [Azure CLI](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli) | 2.63+ |
| [Azure Developer CLI (azd)](https://learn.microsoft.com/en-us/azure/developer/azure-developer-cli/) | 1.23+ |
| [kubectl](https://kubernetes.io/docs/tasks/tools/) | 1.29+ |
| [Helm](https://helm.sh/docs/intro/install/) | 3.14+ |
| [gum](https://github.com/charmbracelet/gum) | For interactive demo scripts (see below) |
| GPU quota | ND H100 v5 family: ≥96 vCPUs in your target region |

### Installing gum

The demo walkthrough scripts use [gum](https://github.com/charmbracelet/gum) for styled terminal output. Install it for your platform:

```bash
# macOS
brew install gum

# Linux
sudo apt install gum        # Debian/Ubuntu (via charm repo)
# or
sudo yum install gum        # Fedora/RHEL
# or download from https://github.com/charmbracelet/gum/releases

# Windows
winget install charmbracelet.gum
# or
scoop install gum
```

## Quick Start

```bash
# Deploy (~13 minutes)
azd up

# Run the interactive demo
./scripts/demo-walkthrough.sh

# Tear down when done
azd down --force --purge
```

## Deploy with MIG

To enable [Multi-Instance GPU](https://docs.nvidia.com/datacenter/tesla/mig-user-guide/index.html) partitioning, set `migMode` before provisioning:

```bash
# 7× 1g.10gb slices per GPU (56 total on 1 node)
azd env set migMode MIG1g
azd up

# 2× 3g.40gb slices per GPU (16 total on 1 node)
azd env set migMode MIG3g
azd up
```

Available profiles: `MIG1g` (7/GPU), `MIG2g` (3/GPU), `MIG3g` (2/GPU), `MIG7g` (full GPU).

> MIG profile **cannot be changed** after creation. Use `azd down` first if switching.

Then run the MIG-specific demo:

```bash
./scripts/demo-mig-walkthrough.sh
```

### H100 MIG Profiles

| Profile | Memory | Compute | Per GPU | K8s Resource |
|---|---|---|---|---|
| `1g.10gb` | 10 GB | 1/7 SMs | 7 | `nvidia.com/mig-1g.10gb` |
| `2g.20gb` | 20 GB | 2/7 SMs | 3 | `nvidia.com/mig-2g.20gb` |
| `3g.40gb` | 40 GB | 3/7 SMs | 2 | `nvidia.com/mig-3g.40gb` |
| `7g.80gb` | 80 GB | 7/7 SMs | 1 | `nvidia.com/mig-7g.80gb` |

## Demo Walkthrough

The `scripts/demo-walkthrough.sh` script is interactive — it pauses between each step so you can narrate:

1. **Cluster overview** — nodes and GPU resources
2. **Kueue config** — ClusterQueues, LocalQueues, Cohort
3. **Submit Team A low-priority job** → admitted against guaranteed quota
4. **Submit Team A high-priority job** → borrows from shared pool
5. **Observe borrowing** — usage exceeds nominal quota
6. **Submit Team B high-priority job** → triggers preemption
7. **Observe preemption** — Team A's borrowed workload evicted
8. **Clean up**

## Coder Workspaces

After deployment, Coder is accessible via its LoadBalancer IP:

```bash
kubectl get svc -n coder

# Or port-forward locally
kubectl port-forward -n coder svc/coder 8080:80
```

Create a workspace from the `ml-workspace` template — it includes Python, PyTorch, CUDA, and `kubectl` with pre-loaded job templates.

## Kueue Concepts

| Concept | Description |
|---|---|
| **ClusterQueue** | Cluster-scoped resource budget with quotas and preemption (admin-managed) |
| **LocalQueue** | Namespace-scoped submission point (user-facing) |
| **Cohort** | Group of ClusterQueues that can borrow/lend resources |
| **ResourceFlavor** | Abstraction for a compute type (e.g., whole H100, MIG 3g.40gb) |
| **Preemption** | Eviction of lower-priority workloads when resources are reclaimed |

> See the [Kueue documentation](https://kueue.sigs.k8s.io/) for full details.

## File Structure

```
├── azure.yaml                  # azd project definition
├── infra/
│   ├── main.bicep              # AKS cluster + GPU node pool (Bicep)
│   ├── main.bicepparam         # Default parameters
│   └── modules/
│       ├── aks-cluster.bicep
│       └── gpu-nodepool.bicep
├── kueue-manifests/            # Reference Kueue CRs (applied by post-provision hook)
├── gpu-operator/               # GPU Operator Helm values for MIG modes
├── coder/                      # Coder Helm values + workspace template
├── demo-jobs/                  # Sample GPU jobs for both teams
└── scripts/
    ├── post-provision.sh       # azd hook: installs Helm charts + Kueue config
    ├── demo-walkthrough.sh     # Interactive multitenancy demo
    └── demo-mig-walkthrough.sh # MIG-specific demo
```

## Troubleshooting

### GPU Drivers Not Loading

**Symptom:** `nvidia.com/gpu` not in node allocatable resources.

**Fix:** Verify GPU Operator pods are running:
```bash
kubectl get pods -n gpu-operator
kubectl logs -n gpu-operator -l app=nvidia-driver-daemonset
```

### Kueue Workloads Stuck in Pending

**Fix:**
1. `kubectl get localqueues -A` — should show `Active: true`
2. `kubectl describe clusterqueue team-a-cq` — check available capacity
3. Verify job has label `kueue.x-k8s.io/queue-name: <localqueue-name>`

### Coder Not Accessible

**Fix:** `kubectl get svc -n coder` — if no external IP, use port-forward:
```bash
kubectl port-forward -n coder svc/coder 8080:80
```

### MIG Resources Not Appearing

**Fix:** Check MIG manager and node labels:
```bash
kubectl get pods -n gpu-operator -l app=nvidia-mig-manager
kubectl get nodes --show-labels | grep mig
```

## References

- [Kueue](https://kueue.sigs.k8s.io/)
- [AKS GPU Best Practices](https://learn.microsoft.com/en-us/azure/aks/best-practices-gpu)
- [NVIDIA MIG User Guide](https://docs.nvidia.com/datacenter/tesla/mig-user-guide/index.html)
- [NVIDIA GPU Operator on AKS](https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/latest/microsoft-aks.html)
- [ND H100 v5 with MIG on AKS](https://techcommunity.microsoft.com/blog/azure-ai-foundry-blog/deploying-azure-nd-h100-v5-instances-in-aks-with-nvidia-mig-gpu-slicing/4384080)
- [Coder v2](https://coder.com/docs/install/kubernetes)
- [Azure Developer CLI](https://learn.microsoft.com/en-us/azure/developer/azure-developer-cli/)

## Production Considerations

This is a demo. For production, add:

| Area | What to Add |
|---|---|
| **Networking** | Private cluster, Azure Firewall, NSGs |
| **Identity** | Entra ID + Kubernetes RBAC, Workload Identity |
| **Database** | External PostgreSQL for Coder |
| **Monitoring** | Prometheus/Grafana for GPU utilization |
| **Storage** | Azure Blob CSI + Azure Files for training data |
| **Autoscaling** | Cluster autoscaler (0→N GPU nodes) |
| **Secrets** | Azure Key Vault with CSI driver |

> ⚠️ **GPU nodes are expensive. Always run `azd down --force --purge` when done.**
