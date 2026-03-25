# CHANGES.md — Observability & Demo Fixes

## Summary

Holistic review and fixes across the entire sample repo, focused on correctness,
consistency, and realistic demo workloads.

---

## Demo Jobs (4 files changed)

**Before:** All jobs ran `nvidia-smi && sleep 600` — zero GPU utilization, all
DCGM panels flat at 0%.

**After:** Real PyTorch training workloads using `pytorch/pytorch:2.5.1-cuda12.4-cudnn9-runtime`:

| Job | Model | Dataset | GPUs | Priority | Epochs |
|-----|-------|---------|------|----------|--------|
| team-a-job-low | ResNet-18 | CIFAR-10 | 2 | low (100) | 200 |
| team-a-job-high | ResNet-50 | CIFAR-100 | 4 | high (1000) | 100 |
| team-b-job-low | VGG-11 | CIFAR-10 | 2 | low (100) | 150 |
| team-b-job-high | DenseNet-121 | CIFAR-100 | 4 | high (1000) | 100 |

All jobs:
- Use `DataParallel` for multi-GPU
- Print epoch-by-epoch loss/accuracy
- Download CIFAR datasets on first run (~170MB)
- Have `activeDeadlineSeconds: 900` (low-pri/MIG) or `1200` (high-pri) as safety
  net — includes CIFAR download time
- Use the same base image as the Coder workspace (no extra image pull)

---

## GPU Cluster Overview Dashboard

1. **Datasource variable**: `${DS_PROMETHEUS}` → `${datasource}` template variable
   (auto-resolves when loaded via Grafana sidecar ConfigMap)

2. **Panel 2 split**: Separated pending workloads (count) from admission wait time
   (seconds) — these were mixed in one panel with incompatible Y-axis scales

3. **Panel 4 rewrite**: Replaced broken GPU-Hours formula (`avg_over_time + $__range_s`
   produced single dots) with "Active GPUs per Namespace" using
   `count by (namespace) (DCGM_FI_DEV_GPU_UTIL{...} > 0)`

4. **5 panels, no overlaps**: Verified all `gridPos` values — clean 2-column layout

---

## DCGM Exporter Dashboard

1. **Fixed overlapping panels**: GPU Utilization and Tensor Core Utilization both
   had `gridPos: {y: 24, x: 0}` — separated to `x: 0` and `x: 12`

2. **Modernized panel types**: Legacy `graph` → `timeseries` (Grafana 9+)

3. **Consistent datasource**: Changed from `$datasource` to `${datasource}` matching
   the GPU Cluster Overview dashboard convention

---

## Monitoring Demo Script (rewritten)

1. **Correct preemption narration**: The 4-job monitoring scenario (A-low, B-low,
   A-high, B-high) results in BOTH low-priority jobs being evicted — not just one.
   
   Preemption trace:
   - team-b-high must borrow → `borrowWithinCohort: LowerPriority` →
     only candidates with priority < 1000
   - team-a-high (priority 1000) is NOT a candidate (equal, not lower)
   - Both low-pri jobs are candidates; evicting one alone (2 GPUs) is insufficient
   - Kueue evicts both to free 4 GPUs for team-b-high

2. **Port-forward fallback**: Tries port 3000, falls back to 8080

3. **Cleanup trap**: Deletes all demo jobs and kills port-forward on Ctrl+C/exit

4. **Panel-specific observation notes**: Each step tells the user exactly which
   Grafana panels to watch and what to expect

---

## Walkthrough Demo Script (narration updated)

- Updated job descriptions to match new ML workloads (ResNet-18, ResNet-50,
  DenseNet-121)
- Preemption narration was already correct for the 3-job scenario (only A-low
  evicted when B-high arrives with 2 idle GPUs available)

---

## Kueue Manifests (consistency fix)

`kueue-manifests/cluster-queues.yaml` had different CPU/memory quotas than what
`deploy.sh` and `post-provision.sh` actually apply. Aligned to match the scripts
(48 CPU nom, 512Gi mem nom per team). Added header warning that these are
reference copies.

---

## Infrastructure

- **Kubernetes version**: 1.33 → 1.34 (1.34 is the current stable default)
- **Coder Helm install**: Both `deploy.sh` and `post-provision.sh` now pass
  `--values coder/values.yaml` to `helm upgrade --install`, ensuring custom
  Coder configuration is applied consistently across deployment methods

---

## Verified (no changes needed)

- **Kueue metric names**: All verified against v0.16.4 source (`pkg/metrics/metrics.go`)
  - `kueue_pending_workloads` ✓
  - `kueue_preempted_workloads_total` with `preempting_cluster_queue` label ✓
  - `kueue_admission_wait_time_seconds_bucket` ✓
- **Helm values**: `enablePrometheus=true` confirmed in Kueue chart v0.16.4
- **GPU Operator**: `dcgmExporter.serviceMonitor.enabled: true` confirmed
- **DCGM metrics**: namespace/pod labels attached when workloads are running ✓

---

## Known Limitations

- **DCGM namespace label**: Sometimes disappears for running workloads after CUDA
  OOM (NVIDIA/dcgm-exporter#342). Not fixable in this sample.
- **CIFAR download**: First run downloads ~170MB per job. Subsequent runs use cache
  if the pod hasn't been recreated.
- **Image pull**: `pytorch/pytorch:2.5.1-cuda12.4-cudnn9-runtime` is ~6GB. First
  pull takes several minutes on fresh nodes. Subsequent pulls are cached.

---

## Remaining TODOs (not addressed)

- `deploy.sh` vs `azd up` — two deployment paths with duplicated Kueue/GPU
  Operator inline YAML. Should refactor to share a common source.
- Coder `CODER_ACCESS_URL` hardcoded to `http://coder.demo.local` — never updated
  with the actual LoadBalancer IP post-deploy.
- Coder workspace uses `pytorch/pytorch` image (~6GB) on system pool with no GPU —
  could use a lighter image since it only needs kubectl/helm.

---

## Audit Fixes

### MIG Mixed Config (CRITICAL)

**Before:** `2× 3g.40gb + 1× 1g.10gb` per GPU = 9 memory slices (only 8 available).
Physically impossible on H100.

**After:** `1× 3g.40gb + 4× 1g.10gb` per GPU = 4 + 4 = 8/8 memory slices ✓

Updated files: `gpu-operator/values-mig-mixed.yaml`, `kueue-manifests/cluster-queues-mig.yaml`
(quotas recalculated: 8 large + 32 small across 8 GPUs).

### Version Bumps

| Component | Before | After | Files |
|-----------|--------|-------|-------|
| Kueue | 0.16.1 | 0.16.4 | `deploy.sh`, `post-provision.sh` |
| bitnami/kubectl | 1.30 | 1.34 | `coder/templates/ml-workspace/main.tf` |
| kube-prometheus-stack | unpinned | 72.6.2 | `deploy.sh`, `post-provision.sh` |

### NC-series H100 Support

Added `Standard_NC40ads_H100_v5` (1× H100 NVL) and `Standard_NC80adis_H100_v5`
(2× H100 NVL) as alternative GPU SKUs alongside the default `Standard_ND96isr_H100_v5`
(8× H100 SXM5).

- Bicep: `@allowed` constraint on `gpuVmSize` in `main.bicep`
- Scripts: `--gpu-sku` flag in `deploy.sh`, `gpuVmSize` env var in `post-provision.sh`
- Kueue quotas computed dynamically from GPU count per SKU
- Cost warning dynamically displays selected SKU
