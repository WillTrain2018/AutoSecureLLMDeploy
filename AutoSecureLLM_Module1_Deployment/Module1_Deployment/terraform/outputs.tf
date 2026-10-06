# =============================================================================
# TC-LLM Local Infrastructure - Outputs
# =============================================================================

output "kube_context" {
  description = "kubeconfig context this configuration targets"
  value       = var.kube_context
}

output "namespace" {
  description = "Namespace the application and its registry credentials deploy into"
  value       = var.namespace
}

output "image_reference" {
  description = "Default Docker Hub image reference wired up for the cluster to pull (the GH Actions deploy job overrides the tag per-deploy)"
  value       = "${var.dockerhub_namespace}/${var.image_name}:${var.image_tag}"
}

output "image_pull_secret" {
  description = "Name of the imagePullSecret created for Docker Hub - referenced by k8s/deployment-blue.yaml and k8s/deployment-green.yaml"
  value       = kubernetes_secret.dockerhub_regcred.metadata[0].name
}

output "load_balancer_enabled" {
  description = "Whether MetalLB was installed in this apply"
  value       = var.enable_load_balancer
}

output "metallb_address_pool_cidr" {
  description = "IP range available for type: LoadBalancer Services, if load balancing is enabled"
  value       = var.enable_load_balancer ? var.metallb_address_pool_cidr : null
}
