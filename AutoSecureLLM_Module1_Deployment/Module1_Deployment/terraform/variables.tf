# =============================================================================
# TC-LLM Local Infrastructure - Variables
# =============================================================================
# Targets the local kind cluster described in this project's own history
# (NOTE 1): context kind-desktop, 2 nodes, Kubernetes v1.36.4, default
# namespace. No AWS, no cloud provider - this replaces M1_main.tf/
# M1_variables.tf/M1_outputs.tf's AWS exercise infra for the actual
# deployment target this project uses.
# =============================================================================

variable "kube_context" {
  description = "kubeconfig context pointing at the local kind cluster"
  type        = string
  default     = "kind-desktop"
}

variable "kubeconfig_path" {
  description = "Path to the kubeconfig file used by both the kubernetes and helm providers"
  type        = string
  default     = "~/.kube/config"
}

variable "namespace" {
  description = "Kubernetes namespace the application deploys into"
  type        = string
  default     = "default"
}

# -----------------------------------------------------------------------------
# Container registry (Docker Hub)
# -----------------------------------------------------------------------------

variable "dockerhub_namespace" {
  description = "Docker Hub account/namespace the image lives under"
  type        = string
  default     = "joecoursera"
}

variable "image_name" {
  description = "Image repository name under the Docker Hub namespace"
  type        = string
  default     = "tc-llm"
}

variable "image_tag" {
  description = "Baseline/default image tag. The GH Actions deploy job overrides this per-deploy via `kubectl set image` with the actual commit-sha tag - this default only matters for a first `terraform apply` before any pipeline run."
  type        = string
  default     = "latest"
}

variable "docker_config_path" {
  description = "Path to this machine's docker config.json. Used to build the cluster's imagePullSecret from the SAME credentials already active on this machine (docker login), mirroring the identical step in .github/workflows/deploy-llm.yml's deploy job, instead of asking for a second, separate login."
  type        = string
  default     = "~/.docker/config.json"
}

# -----------------------------------------------------------------------------
# Load balancing (MetalLB)
# -----------------------------------------------------------------------------

variable "enable_load_balancer" {
  description = "Install MetalLB so `type: LoadBalancer` Services actually get an external IP. kind clusters have no cloud LB implementation out of the box - a LoadBalancer Service just sits in <pending> forever without this. Optional: the application's own Service (k8s/service.yaml) works as ClusterIP regardless, so this can be turned off without breaking anything else."
  type        = bool
  default     = true
}

variable "metallb_chart_version" {
  description = "MetalLB Helm chart version (from https://metallb.github.io/metallb)"
  type        = string
  default     = "0.14.9"
}

variable "metallb_address_pool_cidr" {
  description = "IP range MetalLB hands out for LoadBalancer Services, as a dash-range (e.g. '172.21.255.200-172.21.255.250'). Must sit inside the kind docker network's own subnet (check with `docker network inspect kind`) but outside the range Docker assigns to containers itself - near the top of the subnet is the convention kind's own docs use to avoid collisions."
  type        = string
  default     = "172.21.255.200-172.21.255.250"
}
