# Coder Workspace Template: ML Workspace
# Lightweight pod on system pool — engineers submit GPU jobs via kubectl → Kueue

terraform {
  required_providers {
    coder = {
      source = "coder/coder"
    }
    kubernetes = {
      source = "hashicorp/kubernetes"
    }
  }
}

# Coder data sources

data "coder_workspace" "me" {}
data "coder_workspace_owner" "me" {}

# Parameters — presented to users when creating a workspace

data "coder_parameter" "team_name" {
  name         = "team_name"
  display_name = "Team"
  description  = "Select your team — determines namespace and Kueue queue"
  type         = "string"
  default      = "team-a"
  mutable      = false

  option {
    name  = "Team A"
    value = "team-a"
  }
  option {
    name  = "Team B"
    value = "team-b"
  }
}

data "coder_parameter" "gpu_type" {
  name         = "gpu_type"
  display_name = "GPU Type for Jobs"
  description  = "GPU resource type to use in job templates (workspace itself has no GPU)"
  type         = "string"
  default      = "whole-gpu"
  mutable      = true

  option {
    name  = "Whole GPU (nvidia.com/gpu)"
    value = "whole-gpu"
  }
  option {
    name  = "MIG 3g.40gb (nvidia.com/mig-3g.40gb)"
    value = "mig-3g40gb"
  }
  option {
    name  = "MIG 1g.10gb (nvidia.com/mig-1g.10gb)"
    value = "mig-1g10gb"
  }
}

# Derived values

locals {
  namespace       = data.coder_parameter.team_name.value
  kueue_queue     = "${data.coder_parameter.team_name.value}-lq"
  workspace_name  = "coder-${lower(data.coder_workspace_owner.me.name)}-${lower(data.coder_workspace.me.name)}"

  # Map gpu_type parameter to the Kubernetes resource name
  gpu_resource_map = {
    "whole-gpu"  = "nvidia.com/gpu"
    "mig-3g40gb" = "nvidia.com/mig-3g.40gb"
    "mig-1g10gb" = "nvidia.com/mig-1g.10gb"
  }
  gpu_resource_name = local.gpu_resource_map[data.coder_parameter.gpu_type.value]

  # Job templates to pre-load into the workspace
  job_template_whole_gpu = <<-YAML
    # GPU Training Job Template — Whole GPU
    # Submit with: kubectl apply -f ~/job-templates/train-gpu.yaml
    apiVersion: batch/v1
    kind: Job
    metadata:
      generateName: train-gpu-
      namespace: ${local.namespace}
      labels:
        kueue.x-k8s.io/queue-name: ${local.kueue_queue}
    spec:
      parallelism: 1
      completions: 1
      template:
        spec:
          restartPolicy: Never
          tolerations:
            - key: nvidia.com/gpu
              operator: Exists
              effect: NoSchedule
          containers:
            - name: training
              image: pytorch/pytorch:2.5.1-cuda12.4-cudnn9-runtime
              command: ["bash", "-c"]
              args:
                - |
                  echo "=== GPU Training Job ==="
                  nvidia-smi
                  echo "Training started at $(date)"
                  python -c "import torch; print(f'PyTorch {torch.__version__}, CUDA available: {torch.cuda.is_available()}, Devices: {torch.cuda.device_count()}')"
                  # Replace with actual training script
                  sleep 120
                  echo "Training completed at $(date)"
              resources:
                limits:
                  nvidia.com/gpu: "1"
  YAML

  job_template_mig = <<-YAML
    # GPU Training Job Template — MIG Slice
    # Submit with: kubectl apply -f ~/job-templates/train-mig.yaml
    apiVersion: batch/v1
    kind: Job
    metadata:
      generateName: train-mig-
      namespace: ${local.namespace}
      labels:
        kueue.x-k8s.io/queue-name: ${local.kueue_queue}
    spec:
      parallelism: 1
      completions: 1
      template:
        spec:
          restartPolicy: Never
          tolerations:
            - key: nvidia.com/gpu
              operator: Exists
              effect: NoSchedule
          containers:
            - name: training
              image: pytorch/pytorch:2.5.1-cuda12.4-cudnn9-runtime
              command: ["bash", "-c"]
              args:
                - |
                  echo "=== MIG Slice Training Job ==="
                  nvidia-smi
                  echo "Training on MIG slice started at $(date)"
                  python -c "import torch; print(f'PyTorch {torch.__version__}, CUDA available: {torch.cuda.is_available()}')"
                  sleep 60
                  echo "Training completed at $(date)"
              resources:
                limits:
                  ${local.gpu_resource_name}: "1"
  YAML

  job_template_multi_gpu = <<-YAML
    # Multi-GPU Training Job Template
    # Submit with: kubectl apply -f ~/job-templates/train-multi-gpu.yaml
    apiVersion: batch/v1
    kind: Job
    metadata:
      generateName: train-multi-gpu-
      namespace: ${local.namespace}
      labels:
        kueue.x-k8s.io/queue-name: ${local.kueue_queue}
    spec:
      parallelism: 1
      completions: 1
      template:
        spec:
          restartPolicy: Never
          tolerations:
            - key: nvidia.com/gpu
              operator: Exists
              effect: NoSchedule
          containers:
            - name: training
              image: pytorch/pytorch:2.5.1-cuda12.4-cudnn9-runtime
              command: ["bash", "-c"]
              args:
                - |
                  echo "=== Multi-GPU Training Job (4 GPUs) ==="
                  nvidia-smi
                  python -c "
                  import torch
                  print(f'PyTorch {torch.__version__}')
                  print(f'CUDA devices: {torch.cuda.device_count()}')
                  for i in range(torch.cuda.device_count()):
                      print(f'  GPU {i}: {torch.cuda.get_device_name(i)}')
                  "
                  sleep 180
                  echo "Training completed at $(date)"
              resources:
                limits:
                  nvidia.com/gpu: "4"
  YAML
}

# Coder agent — VS Code web, SSH, and terminal access

resource "coder_agent" "main" {
  os   = "linux"
  arch = "amd64"
  dir  = "/home/coder"

  display_apps {
    vscode     = true
    web_terminal = true
  }

  startup_script = <<-SCRIPT
    #!/bin/bash
    set -e

    # Create job templates directory
    mkdir -p ~/job-templates

    # Write pre-loaded job templates for quick submission
    cat > ~/job-templates/train-gpu.yaml << 'EOF'
    ${local.job_template_whole_gpu}
    EOF

    cat > ~/job-templates/train-mig.yaml << 'EOF'
    ${local.job_template_mig}
    EOF

    cat > ~/job-templates/train-multi-gpu.yaml << 'EOF'
    ${local.job_template_multi_gpu}
    EOF

    # Create a helper script for job submission
    cat > ~/job-templates/submit.sh << 'HELPER'
    #!/bin/bash
    # Quick job submission helper
    # Usage: ./submit.sh <template.yaml>
    if [ -z "$1" ]; then
      echo "Usage: $0 <job-template.yaml>"
      echo "Available templates:"
      ls ~/job-templates/*.yaml
      exit 1
    fi
    echo "Submitting job to namespace: $TEAM_NAMESPACE (queue: $KUEUE_QUEUE_NAME)"
    kubectl apply -f "$1"
    echo ""
    echo "Monitor with:"
    echo "  kubectl get workloads -n $TEAM_NAMESPACE"
    echo "  kubectl get jobs -n $TEAM_NAMESPACE"
    echo "  kubectl get pods -n $TEAM_NAMESPACE"
    HELPER
    chmod +x ~/job-templates/submit.sh

    # Create a README in the home directory
    cat > ~/README.md << 'README'
    # ML Workspace

    ## Quick Start — Submit a GPU Job

    ```bash
    # Submit a single-GPU training job
    kubectl apply -f ~/job-templates/train-gpu.yaml

    # Submit a multi-GPU training job (4 GPUs)
    kubectl apply -f ~/job-templates/train-multi-gpu.yaml

    # Submit a MIG slice job (if MIG is enabled)
    kubectl apply -f ~/job-templates/train-mig.yaml

    # Monitor your jobs
    kubectl get workloads -n $TEAM_NAMESPACE
    kubectl get jobs -n $TEAM_NAMESPACE
    kubectl get pods -n $TEAM_NAMESPACE -w
    ```

    ## Environment
    - **Team Namespace:** $TEAM_NAMESPACE
    - **Kueue Queue:** $KUEUE_QUEUE_NAME
    - **GPU Resource:** $GPU_RESOURCE_NAME
    README

    echo "✅ ML workspace ready! See ~/README.md for quick start."
  SCRIPT

  # Metadata displayed in Coder dashboard
  metadata {
    display_name = "Team"
    key          = "team"
    script       = "echo ${data.coder_parameter.team_name.value}"
    interval     = 0
  }
  metadata {
    display_name = "Namespace"
    key          = "namespace"
    script       = "echo ${local.namespace}"
    interval     = 0
  }
  metadata {
    display_name = "Queue"
    key          = "queue"
    script       = "echo ${local.kueue_queue}"
    interval     = 0
  }
  metadata {
    display_name = "GPU Type"
    key          = "gpu_type"
    script       = "echo ${local.gpu_resource_name}"
    interval     = 0
  }
}

# Kubernetes pod — runs on system pool, NO GPU

resource "kubernetes_pod" "workspace" {
  count = data.coder_workspace.me.start_count

  metadata {
    name      = local.workspace_name
    namespace = local.namespace
    labels = {
      "app.kubernetes.io/name"     = "coder-workspace"
      "app.kubernetes.io/instance" = local.workspace_name
    }
  }

  spec {
    service_account_name = "coder-workspace-sa"

    # Run on system pool — no GPU tolerations
    node_selector = {
      "kubernetes.io/os" = "linux"
    }

    init_container {
      name  = "install-tools"
      image = "bitnami/kubectl:1.30"
      command = ["sh", "-c"]
      args = [<<-EOT
        # Copy kubectl binary to shared volume
        cp /opt/bitnami/kubectl/bin/kubectl /tools/kubectl

        # Download and install Helm
        curl -fsSL https://get.helm.sh/helm-v3.16.0-linux-amd64.tar.gz | tar xz -C /tmp
        cp /tmp/linux-amd64/helm /tools/helm

        chmod +x /tools/kubectl /tools/helm
        echo "Tools installed: kubectl, helm"
      EOT
      ]

      volume_mount {
        name       = "tools"
        mount_path = "/tools"
      }
    }

    container {
      name  = "workspace"
      image = "pytorch/pytorch:2.5.1-cuda12.4-cudnn9-runtime"
      command = ["sh", "-c", coder_agent.main.init_script]

      # Workspace resources — lightweight, no GPU
      resources {
        requests = {
          cpu    = "1"
          memory = "2Gi"
        }
        limits = {
          cpu    = "2"
          memory = "4Gi"
        }
      }

      # Environment variables for job templates and kubectl context
      env {
        name  = "TEAM_NAMESPACE"
        value = local.namespace
      }
      env {
        name  = "KUEUE_QUEUE_NAME"
        value = local.kueue_queue
      }
      env {
        name  = "GPU_RESOURCE_NAME"
        value = local.gpu_resource_name
      }
      env {
        name  = "CODER_AGENT_TOKEN"
        value = coder_agent.main.token
      }

      # Persistent home directory (emptyDir for demo — data lost on pod delete)
      volume_mount {
        name       = "home"
        mount_path = "/home/coder"
      }

      # Shared tools volume (kubectl, helm from init container)
      volume_mount {
        name       = "tools"
        mount_path = "/usr/local/bin/kubectl"
        sub_path   = "kubectl"
      }
      volume_mount {
        name       = "tools"
        mount_path = "/usr/local/bin/helm"
        sub_path   = "helm"
      }
    }

    # emptyDir for home — demo only; use PVC for production
    volume {
      name = "home"
      empty_dir {}
    }

    volume {
      name = "tools"
      empty_dir {}
    }
  }
}
