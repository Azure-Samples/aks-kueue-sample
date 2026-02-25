# =============================================================================
# Variables for ML Workspace Template
# =============================================================================
# These variables are used by the Terraform template but are primarily
# controlled via Coder parameters (data "coder_parameter" blocks in main.tf).
# They serve as fallback defaults and can be overridden via Coder template
# variables when pushing the template with `coder templates push`.
# =============================================================================

variable "team_name" {
  type        = string
  description = "Team name — determines the Kubernetes namespace and Kueue LocalQueue"
  default     = "team-a"

  validation {
    condition     = contains(["team-a", "team-b"], var.team_name)
    error_message = "team_name must be 'team-a' or 'team-b'."
  }
}

variable "gpu_type" {
  type        = string
  description = "GPU resource type for job templates: whole-gpu, mig-3g40gb, or mig-1g10gb"
  default     = "whole-gpu"

  validation {
    condition     = contains(["whole-gpu", "mig-3g40gb", "mig-1g10gb"], var.gpu_type)
    error_message = "gpu_type must be 'whole-gpu', 'mig-3g40gb', or 'mig-1g10gb'."
  }
}

variable "namespace" {
  type        = string
  description = "Kubernetes namespace for the workspace (derived from team_name)"
  default     = ""
}

variable "kueue_queue_name" {
  type        = string
  description = "Kueue LocalQueue name (derived from team_name, e.g., team-a-lq)"
  default     = ""
}

# ---------------------------------------------------------------------------
# Computed locals — derive namespace and queue from team_name when not
# explicitly provided
# ---------------------------------------------------------------------------

locals {
  # Namespace matches the team name (team-a → team-a namespace)
  effective_namespace = var.namespace != "" ? var.namespace : var.team_name

  # LocalQueue follows the convention: <team-name>-lq
  effective_queue = var.kueue_queue_name != "" ? var.kueue_queue_name : "${var.team_name}-lq"
}
