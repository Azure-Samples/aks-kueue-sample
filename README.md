# AKS ML Cluster with Kueue Multitenancy & Coder IDE

A sample AKS deployment with NVIDIA H100 GPUs, [Kueue](https://kueue.sigs.k8s.io/) for multitenant GPU scheduling, and [Coder v2](https://coder.com/) as a browser-based development environment.

**What it demonstrates:**

- **Fair-sharing** — guaranteed GPU quotas per team with burst borrowing
- **Preemption** — high-priority jobs reclaim borrowed resources automatically
- **MIG partitioning** (optional) — split H100s into isolated GPU instances
- **Coder IDE** — submit GPU jobs from a browser-based VS Code workspace

## Architecture

The cluster runs two node pools. The system pool hosts Kueue and Coder. The GPU pool runs H100 VMs (ND-series 8-GPU or NC-series 1–2 GPU) managed by the NVIDIA GPU Operator. Kueue enforces per-team quotas through three ClusterQueues in a shared Cohort, enabling borrowing and preemption across teams.

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
| [gum](https://github.com/charmbracelet/gum#installation) | For interactive demo scripts |
| GPU quota | ND H100 v5 or NC H100 v5 family vCPUs in your target region (see GPU SKU table) |

## Quick Start

```bash
# Deploy with default ND-series 8×H100 (~13 minutes)
azd up

# Or deploy with NC-series 2×H100 (lower cost)
azd env set gpuVmSize Standard_NC80adis_H100_v5
azd up

# Run the interactive demo
./scripts/demo-walkthrough.sh

# Tear down when done
azd down --force --purge
```

## GPU VM Options

| SKU | GPUs | Memory/GPU | Interconnect | vCPUs | Use Case |
|---|---|---|---|---|---|
| `Standard_ND96isr_H100_v5` (default) | 8× H100 SXM5 | 80 GB | InfiniBand + NVLink | 96 | Multi-GPU training, large models |
| `Standard_NC80adis_H100_v5` | 2× H100 NVL | 94 GB | NVLink (no IB) | 80 | Medium-scale training, inference |
| `Standard_NC40ads_H100_v5` | 1× H100 NVL | 94 GB | — | 40 | Single-GPU fine-tuning, dev/test |

Select via `azd env set gpuVmSize <SKU>` or `./scripts/deploy.sh --gpu-sku <SKU>`.

Kueue quotas adjust automatically based on GPU count per node. Demo walkthrough scripts auto-detect available GPUs and select appropriate job variants (single-GPU for NC-series, multi-GPU for ND-series).

> **Note:** NC-series H100 NVL GPUs have 94 GB memory (vs 80 GB on ND-series SXM5) but lack InfiniBand. MIG is supported on both series.

> **Note:** The default demo jobs (`demo-jobs/team-*-job-{low,high}.yaml`) request 2–4 GPUs
> and are designed for the ND-series (8 GPUs). For NC-series nodes (1–2 GPUs), the demo scripts
> automatically switch to single-GPU variants (`team-*-job-single-gpu.yaml`). You can also
> run them manually:
> ```bash
> kubectl apply -f demo-jobs/team-a-job-single-gpu.yaml
> kubectl apply -f demo-jobs/team-b-job-single-gpu.yaml
> ```

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

Available profiles: `MIG1g` (7/GPU), `MIG2g` (3/GPU), `MIG3g` (2/GPU), `MIG4g` (1/GPU), `MIG7g` (full GPU).

MIG profiles can be changed on a running cluster by relabeling the GPU node:

```bash
kubectl label node <gpu-node> nvidia.com/mig.config=all-1g.10gb --overwrite
```

The GPU Operator reconfigures the GPUs in ~90 seconds. No redeployment needed.

Then run the MIG-specific demo:

```bash
./scripts/demo-mig-walkthrough.sh
```

### H100 MIG Profiles

MIG profile sizes depend on the GPU memory variant. The deploy scripts automatically select the correct profiles based on the GPU SKU.

**H100 SXM5 — 80 GB (ND-series)**

| Profile | Memory | Compute | Per GPU | K8s Resource |
|---|---|---|---|---|
| `1g.10gb` | 10 GB | 1/7 SMs | 7 | `nvidia.com/mig-1g.10gb` |
| `2g.20gb` | 20 GB | 2/7 SMs | 3 | `nvidia.com/mig-2g.20gb` |
| `3g.40gb` | 40 GB | 3/7 SMs | 2 | `nvidia.com/mig-3g.40gb` |
| `4g.40gb` | 40 GB | 4/7 SMs | 1 | `nvidia.com/mig-4g.40gb` |
| `7g.80gb` | 80 GB | 7/7 SMs | 1 | `nvidia.com/mig-7g.80gb` |

**H100 NVL — 94 GB (NC-series)**

| Profile | Memory | Compute | Per GPU | K8s Resource |
|---|---|---|---|---|
| `1g.12gb` | 12 GB | 1/7 SMs | 7 | `nvidia.com/mig-1g.12gb` |
| `2g.24gb` | 24 GB | 2/7 SMs | 3 | `nvidia.com/mig-2g.24gb` |
| `3g.47gb` | 47 GB | 3/7 SMs | 2 | `nvidia.com/mig-3g.47gb` |
| `4g.47gb` | 47 GB | 4/7 SMs | 1 | `nvidia.com/mig-4g.47gb` |
| `7g.94gb` | 94 GB | 7/7 SMs | 1 | `nvidia.com/mig-7g.94gb` |

## Coder Workspaces

After deployment, Coder is accessible via its LoadBalancer IP:

```bash
kubectl get svc -n coder

# Or port-forward locally
kubectl port-forward -n coder svc/coder 8080:80
```

Create a workspace from the `ml-workspace` template — it includes Python, PyTorch, CUDA, and `kubectl` with pre-loaded job templates.

## Monitoring (Optional)

Deploy a Prometheus + Grafana observability stack to visualize GPU utilization, Kueue queue health, and preemption events.

### Enable with azd

```bash
azd env set enableMonitoring true
azd up
```

### Enable with standalone deploy

```bash
./scripts/deploy.sh --monitoring

# Or with a specific GPU SKU
./scripts/deploy.sh --monitoring --gpu-sku Standard_NC80adis_H100_v5
```

### What gets deployed

- **kube-prometheus-stack** in the `monitoring` namespace (Prometheus, Grafana, kube-state-metrics)
- **DCGM Exporter ServiceMonitor** — scrapes GPU metrics (utilization, memory, power, temperature)
- **Kueue ServiceMonitor** — scrapes queue metrics (pending workloads, admission latency, preemptions)
- Two **Grafana dashboards** auto-provisioned under the "GPU Observability" folder:

| Dashboard | Panels | Purpose |
|---|---|---|
| **GPU Cluster Overview** | GPU utilization per namespace, queue depth & wait times, preemption events, GPU-hours per namespace | Multitenancy view — ties GPU usage to Kueue queues |
| **NVIDIA DCGM Exporter** | Per-GPU temperature, power draw, SM/memory clocks, memory utilization, SM utilization, encoder/decoder utilization, PCIe errors, energy consumption | Hardware view — per-GPU detail for all H100s on the node |

### Access Grafana

```bash
kubectl port-forward -n monitoring svc/prometheus-grafana 3000:80
# Open http://localhost:3000 — login: admin / demo
```

### Run the monitoring demo

Submit jobs that light up all dashboard panels (queue pressure, preemption, GPU utilization):

```bash
./scripts/demo-monitoring.sh
```

## File Structure

```
├── azure.yaml                  # azd project definition
├── infra/
│   ├── main.bicep              # AKS cluster + GPU node pool (Bicep)
│   ├── main.bicepparam         # Default parameters
│   └── modules/
│       ├── aks-cluster.bicep
│       └── gpu-nodepool.bicep
├── monitoring/                 # Observability stack configs (optional)
│   ├── values-prometheus-stack.yaml
│   ├── values-gpu-operator-monitoring.yaml
│   └── dashboards/
│       ├── gpu-cluster-overview.json
│       └── dcgm-exporter-dashboard.json
├── kueue-manifests/            # Reference Kueue CRs (applied by post-provision hook)
├── gpu-operator/               # GPU Operator Helm values for MIG modes
├── coder/                      # Coder Helm values + workspace template
├── demo-jobs/                  # Sample GPU jobs for both teams
└── scripts/
    ├── post-provision.sh       # azd hook: installs Helm charts + Kueue config
    ├── deploy.sh               # Standalone deploy (--monitoring flag)
    ├── teardown.sh             # Resource cleanup
    ├── demo-walkthrough.sh     # Interactive multitenancy demo
    ├── demo-mig-walkthrough.sh # MIG-specific demo
    └── demo-monitoring.sh      # Monitoring dashboard demo
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
- [NCads H100 v5 Series](https://learn.microsoft.com/en-us/azure/virtual-machines/ncads-h100-v5)
- [Coder v2](https://coder.com/docs/install/kubernetes)
- [Azure Developer CLI](https://learn.microsoft.com/en-us/azure/developer/azure-developer-cli/)

> ⚠️ **GPU nodes are expensive. Always run `azd down --force --purge` when done.**
