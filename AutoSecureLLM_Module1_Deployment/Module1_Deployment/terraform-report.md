# Terraform: Local Infrastructure Report

Covers the new `terraform/` directory — provider/backend/registry/load-balancer setup
for the actual local deployment target (kind cluster, Docker Hub), separate from the
AWS-focused `M1_main.tf`/`M1_variables.tf`/`M1_outputs.tf` training exercise files, which
are untouched. **Stopped at `terraform plan` as requested — nothing below was applied.**

## Files created

| File | Contents |
|---|---|
| `terraform/main.tf` | `terraform`/backend block, both providers, all 5 resources |
| `terraform/variables.tf` | Cluster context, namespace, Docker Hub coordinates, MetalLB settings |
| `terraform/outputs.tf` | Context, namespace, image reference, pull-secret name, LB status/CIDR |
| `terraform/templates/metallb-pool.yaml.tpl` | MetalLB `IPAddressPool`/`L2Advertisement` template |

## Provider configuration — local Kubernetes (kind)

`hashicorp/kubernetes` (~> 2.33) and `hashicorp/helm` (resolved to v3.3.0), both pointed
at the `kind-desktop` context via the normal kubeconfig — the same cluster confirmed
earlier in this project (2 nodes, v1.36.4, matching NOTE 1 exactly). No cloud provider
block at all.

**Decision worth recording:** there's a community `tehcyx/kind` provider that can create
kind clusters declaratively from Terraform. Not used here — the cluster already exists
and matches the stated spec, so Terraform's job is managing *resources inside* it
(registry credentials, MetalLB), not the cluster's own lifecycle. Worth revisiting if the
cluster ever needs to be reproducible from scratch via `terraform apply` alone.

**Found and fixed while actually running this, not assumed correct:**
- Both the backend and provider connections need `insecure = true` explicitly. They do
  **not** automatically inherit the `insecure-skip-tls-verify: true` already set on the
  `kind-desktop` kubeconfig entry (the workaround for Norton's local TLS interception,
  from earlier in this project) the way plain `kubectl` does.
- The Helm provider resolved to v3.3.0, which uses object-attribute syntax
  (`kubernetes = { ... }`) for its connection config, not the older block syntax
  (`kubernetes { ... }`) I wrote first — caught by the IDE's Terraform diagnostics before
  it ever reached `plan`.
- The `kubernetes` *backend* block needs `load_config_file = true` set explicitly — unlike
  the provider block, it doesn't read the kubeconfig at all without it, and silently fell
  back to an empty default config (`http://localhost`) instead of erroring clearly.

## Backend configuration — state management

```hcl
backend "kubernetes" {
  secret_suffix    = "tc-llm-state"
  namespace        = "default"
  config_path      = "~/.kube/config"
  config_context   = "kind-desktop"
  load_config_file = true
  insecure         = true
}
```

State is stored as a Secret **inside the kind cluster itself**, not a local file or a
cloud backend (S3, etc.) — this project uses no cloud services at all, so this keeps
state self-contained alongside everything else Terraform manages here.

**Verified, not assumed:** `terraform init` created `secret/tfstate-default-tc-llm-state`
in the `default` namespace (confirmed via `kubectl get secret -l tfstate=true`), and no
local `.tfstate` file exists anywhere in the working directory.

## Container registry — Docker Hub

Docker Hub has no first-party Terraform provider for repository lifecycle management,
and `joecoursera/tc-llm` already exists (auto-created by the first `docker push` earlier
in this project). What Terraform meaningfully owns instead: a `kubernetes_secret`
imagePullSecret built from this machine's own `docker login` session —

```hcl
resource "kubernetes_secret" "dockerhub_regcred" {
  metadata { name = "dockerhub-regcred"; namespace = var.namespace }
  type = "kubernetes.io/dockerconfigjson"
  data = { ".dockerconfigjson" = file(pathexpand(var.docker_config_path)) }
}
```

— the identical approach already used in `.github/workflows/deploy-llm.yml`'s deploy job,
duplicated here so a bare `terraform apply` on a fresh cluster is sufficient on its own,
without requiring a pipeline run first.

**Security note:** like any Terraform-managed Secret, this credential ends up in
Terraform state (i.e., inside the `tfstate-default-tc-llm-state` Secret above) in
addition to the `dockerhub-regcred` Secret itself. That's standard Terraform behavior for
secret-type resources generally, not specific to this setup — and `terraform plan`'s
saved plan file (`tfplan.out`) retains the real value internally too, even where its
*terminal* output masks it as `(sensitive value)`. Added `tfplan.out`/`*.tfplan` to
`.gitignore` and deleted the one generated during this session.

## Load balancing — MetalLB (assessed as available and capable)

**Assessment:** kind clusters have no cloud LoadBalancer implementation — a
`type: LoadBalancer` Service just sits `<pending>` forever without one. MetalLB is the
standard bare-metal solution and what kind's own docs recommend. Confirmed capable here:
`docker network inspect kind` shows the cluster's docker network as `172.21.0.0/16`, with
room for a small address pool (`172.21.255.200-172.21.255.250`) outside the range Docker
assigns to the node containers themselves (`.2`, `.3`).

Installed conditionally via `var.enable_load_balancer` (default `true`) — optional
infrastructure; the application's own blue-green Service (`k8s/service.yaml`) works as
`ClusterIP` regardless of whether this is enabled.

**Found and fixed while running this:**
- `helm_release.metallb` initially failed: `Unable to locate chart metallb: no cached
  repo found`, referencing an unrelated repo (`prometheus-community-index.yaml`). Root
  cause: this machine already had `prometheus-community` and `kedacore` repos
  *registered* (`helm repo list`) but with **no cached index file on disk at all** for
  either — stale leftovers from unrelated prior work. The provider's chart resolution
  walks every registered repo's cache and fails hard on the first missing one, not
  specifically on MetalLB's.
- Fix: a `null_resource` with a `local-exec` provisioner runs `helm repo add metallb ...`
  and an unscoped `helm repo update` (refreshing *every* registered repo, not just
  `metallb`) before `helm_release.metallb`, so a fresh machine doesn't need this done by
  hand first.
- MetalLB's `IPAddressPool`/`L2Advertisement` CRs are applied via a second `null_resource`
  running `kubectl apply`, not a native `kubernetes_manifest` resource — that resource
  type validates CRD schemas at **plan** time, before the CRD the same apply installs
  even exists yet. Applying via `kubectl` sidesteps the ordering problem entirely.

## `terraform plan` summary

**Plan: 5 to add, 0 to change, 0 to destroy.**

| # | Resource | What it does |
|---|---|---|
| 1 | `null_resource.helm_repo_metallb` | Registers + refreshes Helm repos (fixes the stale-cache issue above) |
| 2 | `helm_release.metallb[0]` | Installs MetalLB v0.14.9 into a new `metallb-system` namespace |
| 3 | `local_file.metallb_address_pool_manifest[0]` | Renders the `IPAddressPool`/`L2Advertisement` YAML to `.generated/metallb-pool.yaml` |
| 4 | `null_resource.metallb_address_pool[0]` | Waits for MetalLB's controller, then `kubectl apply`s the rendered manifest |
| 5 | `kubernetes_secret.dockerhub_regcred` | Creates the Docker Hub imagePullSecret in `default` |

Proposed outputs:

```
image_pull_secret         = "dockerhub-regcred"
image_reference           = "joecoursera/tc-llm:latest"
kube_context              = "kind-desktop"
load_balancer_enabled     = true
metallb_address_pool_cidr = "172.21.255.200-172.21.255.250"
namespace                 = "default"
```

## Not done (explicitly out of scope for this task)

- `terraform apply` — stopped at plan as requested; nothing above has actually been
  created in the cluster yet except the state-backend Secret itself (an unavoidable side
  effect of `terraform init` using the `kubernetes` backend).
- Managing the kind cluster's own lifecycle (create/destroy) via Terraform — see the
  `tehcyx/kind` provider note above.
- Reconciling whether `.terraform.lock.hcl` should be committed. It's currently
  `.gitignore`d (inherited from this repo's existing Terraform section) — Hashicorp's own
  guidance since ~2019 is to commit it for reproducible provider versions across
  machines; worth a deliberate decision rather than leaving it as an inherited default.
