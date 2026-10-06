# =============================================================================
# TC-LLM Local Infrastructure
# =============================================================================
# Local kind cluster + Docker Hub, no AWS/cloud provider at all. See
# ../terraform-report.md for what this does and the actual `terraform
# plan` output reviewed when this was built.
# =============================================================================

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.33"
    }
    helm = {
      source  = "hashicorp/helm"
      version = ">= 2.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
  }

  # State management: stored as a Secret INSIDE the kind cluster itself
  # (Terraform's native "kubernetes" backend), not a local file or a cloud
  # backend (S3, etc.) - this project uses no cloud services at all, so
  # this keeps state self-contained alongside everything else here.
  #
  # Backend blocks can't reference variables (resolved before the rest of
  # the config loads), so the context/path are repeated as literals here -
  # they match var.kube_context/var.kubeconfig_path below intentionally.
  #
  # insecure = true: the backend's own HTTP client does NOT automatically
  # honor the insecure-skip-tls-verify already set on the kind-desktop
  # cluster entry in kubeconfig the way plain `kubectl` does - it needs
  # telling explicitly. Same root cause as everywhere else in this
  # project: Norton's local TLS-interception (see the chat history), not
  # a problem with the cluster's real certificate.
  backend "kubernetes" {
    secret_suffix    = "tc-llm-state"
    namespace        = "default"
    config_path      = "~/.kube/config"
    config_context   = "kind-desktop"
    load_config_file = true
    insecure         = true
  }
}

# -----------------------------------------------------------------------------
# Provider: local Kubernetes (kind)
# -----------------------------------------------------------------------------
# Targets the already-running kind cluster via the same kubeconfig kubectl
# itself uses. insecure = true for the same Norton TLS-interception reason
# as the backend block above - no cloud provider, no separate credentials
# otherwise.
provider "kubernetes" {
  config_path    = var.kubeconfig_path
  config_context = var.kube_context
  insecure       = true
}

provider "helm" {
  kubernetes = {
    config_path    = var.kubeconfig_path
    config_context = var.kube_context
    insecure       = true
  }
}

# This machine has three bash.exe candidates on PATH (Git Bash, the WSL
# launcher at C:\Windows\System32\bash.exe, and a WindowsApps stub) - an
# unqualified "bash" in a local-exec interpreter resolved to the WSL one
# in at least one shell context, where Windows-installed CLIs like helm
# aren't on PATH at all. Every local-exec provisioner below pins this
# exact path instead. Not portable to a non-Windows runner as-is; if this
# ever runs on Linux/macOS CI, this should become `"/bin/bash"` or be
# conditioned on `var.kube_context`'s host OS.
locals {
  git_bash = "C:/Program Files/Git/usr/bin/bash.exe"
}

# -----------------------------------------------------------------------------
# Container registry: Docker Hub
# -----------------------------------------------------------------------------
# Docker Hub has no first-party Terraform provider for repository
# lifecycle management, and joecoursera/tc-llm already exists - Docker Hub
# auto-creates a repo on first `docker push`, which already happened.
# What Terraform meaningfully owns here instead is wiring the CLUSTER up
# to pull from it: an imagePullSecret built from this machine's own
# `docker login` session, identical in approach to the
# "Create/update Docker Hub imagePullSecret" step in
# .github/workflows/deploy-llm.yml's deploy job (kept here too so a bare
# `terraform apply` on a fresh cluster is enough on its own, without
# requiring a pipeline run first).
#
# Note on state sensitivity: like any Terraform-managed Secret, this
# credential ends up in Terraform state (in the kubernetes-backend Secret
# above) as well as in the dockerhub-regcred Secret itself. That's
# standard Terraform behavior for secret-type resources generally, not
# specific to this setup - securing access to the state backend is the
# usual mitigation, not avoiding Terraform-managed secrets.
resource "kubernetes_secret" "dockerhub_regcred" {
  metadata {
    name      = "dockerhub-regcred"
    namespace = var.namespace
  }

  type = "kubernetes.io/dockerconfigjson"

  data = {
    ".dockerconfigjson" = file(pathexpand(var.docker_config_path))
  }
}

# -----------------------------------------------------------------------------
# Load balancing: MetalLB (if available and capable)
# -----------------------------------------------------------------------------
# Assessment: kind clusters have no cloud LoadBalancer implementation -
# a `type: LoadBalancer` Service stays <pending> forever without one.
# MetalLB is the standard bare-metal solution and what kind's own docs
# recommend for exactly this. It IS capable here: the kind docker network
# (172.21.0.0/16, confirmed via `docker network inspect kind`) has room
# for a small address pool outside Docker's own container IP range.
# Installed conditionally - optional infra, not something the
# application strictly needs (k8s/service.yaml works as ClusterIP
# regardless of whether this is enabled).
# Prerequisite found by actually running `terraform plan`, not assumed:
# the helm provider's chart lookup failed ("Unable to locate chart
# metallb: no cached repo found") against an inline repository URL. The
# real cause: this machine had OTHER repos (prometheus-community,
# kedacore) already registered with NO cached index file on disk at all
# (stale, from unrelated prior work) - the provider's chart resolution
# apparently walks every registered repo's cache and fails hard on the
# first missing one, not specifically on metallb's. `helm repo update`
# with no args refreshes every registered repo's cache, which is why
# this runs unscoped rather than just `helm repo update metallb`.
resource "null_resource" "helm_repo_metallb" {
  provisioner "local-exec" {
    # Pinned to Git Bash's full path, not a bare "bash" - this machine
    # has THREE bash.exe candidates on PATH (Git Bash, the WSL launcher
    # at C:\Windows\System32\bash.exe, and a WindowsApps stub), and an
    # unqualified "bash" resolved to the WSL one in at least one shell
    # context `terraform apply` was run from. helm.exe lives at a Windows
    # path (WinGet-installed), invisible from inside WSL without an
    # explicit /mnt/c/... reference - hence "helm: command not found"
    # even though helm is genuinely installed and on this machine's PATH.
    interpreter = [local.git_bash, "-c"]
    command     = "helm repo add metallb https://metallb.github.io/metallb && helm repo update"
  }
}

resource "helm_release" "metallb" {
  count = var.enable_load_balancer ? 1 : 0

  depends_on = [null_resource.helm_repo_metallb]

  name             = "metallb"
  repository       = "https://metallb.github.io/metallb"
  chart            = "metallb"
  version          = var.metallb_chart_version
  namespace        = "metallb-system"
  create_namespace = true

  wait    = true
  timeout = 180
}

# MetalLB's IPAddressPool/L2Advertisement are CRDs this same helm_release
# installs - see the comment in templates/metallb-pool.yaml.tpl for why
# these are applied via kubectl instead of a native kubernetes_manifest
# resource (a CRD-timing limitation of that resource type, not a
# workaround for anything broken in MetalLB itself).
resource "local_file" "metallb_address_pool_manifest" {
  count = var.enable_load_balancer ? 1 : 0

  filename = "${path.module}/.generated/metallb-pool.yaml"
  content = templatefile("${path.module}/templates/metallb-pool.yaml.tpl", {
    cidr = var.metallb_address_pool_cidr
  })
}

resource "null_resource" "metallb_address_pool" {
  count = var.enable_load_balancer ? 1 : 0

  depends_on = [helm_release.metallb, local_file.metallb_address_pool_manifest]

  triggers = {
    manifest_hash = sha256(local_file.metallb_address_pool_manifest[0].content)
  }

  provisioner "local-exec" {
    # See the comment on null_resource.helm_repo_metallb above - same fix,
    # pinned Git Bash path instead of an ambiguous bare "bash".
    interpreter = [local.git_bash, "-c"]
    command     = <<-EOT
      kubectl --context ${var.kube_context} wait --for=condition=Available --timeout=120s -n metallb-system deployment/metallb-controller
      kubectl --context ${var.kube_context} apply -f "${local_file.metallb_address_pool_manifest[0].filename}"
    EOT
  }
}
