# Reconfiguration: AWS → local Kubernetes

`deploy-llm.yml`'s `deploy` job originally targeted AWS (ECR push, ALB blue/green target
groups, SSM Parameter Store for color state). This doc records why and what changed when
it was reconfigured to target a local cluster instead.

## Why

No AWS is used for this deployment. The actual target is a local Kubernetes cluster:
`docker-desktop`/`kind` context, 2 nodes, Kubernetes v1.36.4, `default` namespace,
`kubectl`-driven.

## What changed

| Concern | Before (AWS) | Now (local k8s + Docker Hub) |
|---|---|---|
| Registry | ECR, via `aws-actions/amazon-ecr-login` + `docker push` | Docker Hub (`joecoursera/tc-llm`), via `docker login`/`docker push` |
| Credentials | `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` secrets | None required - this machine is already logged in to Docker Hub; optional `DOCKERHUB_USERNAME`/`DOCKERHUB_TOKEN` secrets for a future runner that isn't |
| Color state | SSM Parameter Store (`aws ssm get/put-parameter`) | Kubernetes ConfigMap (`tc-llm-active-color`) |
| Traffic switch | `aws elbv2 modify-listener` on the ALB | `kubectl patch service` on the Service's `color` selector |
| Health validation | `aws elbv2 describe-target-health` + curl against the ALB DNS | `kubectl rollout status` (pre-flip) + curl through a `kubectl port-forward` (post-flip) |
| Where it deploys to | `aws_instance.llm_inference` compute (M1_main.tf, still commented out) | Two Kubernetes Deployments (`tc-llm-blue`/`tc-llm-green`), new files under `k8s/` |
| Getting the image onto the cluster | N/A | `kubectl set image` + kubelet pulls from Docker Hub directly, using an `imagePullSecret` built from this machine's own `docker login` session (see below) |
| Runner | `ubuntu-latest` (GitHub-hosted) | `self-hosted` for both `build` and `deploy` - `deploy` because it must reach localhost; `build` because this machine is already authenticated to Docker Hub |

### Revision: Docker Hub instead of a registry-less local load

The first version of this reconfiguration avoided a registry entirely - `build` only
built+loaded the image locally, and `deploy` used `kind load docker-image` to inject it
directly into the cluster's node containerd stores. That's now replaced with a real
Docker Hub push/pull, which actually **simplifies** `deploy`: no more branching on
whether the active context is `kind`-CLI-managed vs. Docker Desktop's built-in engine -
kubelet just pulls `joecoursera/tc-llm:<sha>` like it would from any other registry.

The one new piece this needs: if `joecoursera/tc-llm` is (or ever becomes) a private
repo, the cluster's kubelet needs its own credentials to pull from it - a kind node is a
separate container with its own containerd, it doesn't share the host's `~/.docker/`
credential store automatically. The `deploy` job handles this by copying this exact
machine's existing Docker config into a Kubernetes `imagePullSecret`:

```yaml
- name: Create/update Docker Hub imagePullSecret
  run: |
    kubectl create secret generic dockerhub-regcred \
      --from-file=.dockerconfigjson="${HOME}/.docker/config.json" \
      --type=kubernetes.io/dockerconfigjson \
      --namespace "$K8S_NAMESPACE" \
      --dry-run=client -o yaml | kubectl apply -f -
```

**Verified this will actually work, not just assumed:** checked the structure of this
machine's `~/.docker/config.json` (keys only, no secret values printed) and confirmed it
holds a real embedded `auth` token under `auths["https://index.docker.io/v1/"]`, with no
`credsStore`/`credHelpers` delegating to an external credential manager. If it *had* been
delegated (common on a fresh Docker Desktop install, e.g. `credsStore: desktop`), this
file would contain no usable token at all and the pull secret would silently be useless -
worth re-checking this if `docker login` is ever redone on this machine.

One portability note: `${HOME}` must resolve, on whatever machine actually runs the
self-hosted runner process, to the same user profile that ran `docker login`. On a
Windows box running as a background service under a different account than the
interactive login, these can diverge - confirm `%USERPROFILE%\.docker\config.json` exists
for the account the runner service actually runs as before relying on this step.

## New files

- `AutoSecureLLM_Module1_Deployment/Module1_Deployment/k8s/deployment-blue.yaml`
- `AutoSecureLLM_Module1_Deployment/Module1_Deployment/k8s/deployment-green.yaml`
- `AutoSecureLLM_Module1_Deployment/Module1_Deployment/k8s/service.yaml`

Each Deployment reuses the `/health/ready` and `/health/live` endpoints already built
into `M1_app.py` as `readinessProbe`/`livenessProbe`. The idle color starts at
`replicas: 0`; the pipeline scales it up, validates it, flips the Service, then scales
the old color back down to 0.

## The one hard constraint this introduces

GitHub-hosted runners cannot reach `localhost` on your machine, and with no registry,
there's also no shared hand-off point between a hosted `build` job and a different
machine's `deploy` job. **Both jobs now require a self-hosted runner** registered on the
same machine running `docker-desktop`/kind. Without that runner registered, this workflow
cannot execute at all — it isn't a bug, it's the nature of "deploy to my own laptop" CI.

## Open item worth flagging

NOTE 1 stated the context as `docker-desktop`, but checking the actual running
containers showed `desktop-control-plane` + `desktop-worker`, both `kindest/node:v1.36.4`
— exactly 2 nodes, exactly the stated k8s version — which is the `kind-desktop` context,
not `docker-desktop` (Docker Desktop's separate, normally single-node built-in
Kubernetes). This doesn't need resolving before anything works: the `kind load` step
derives the cluster name from whichever context is actually active at runtime rather than
assuming one, so the workflow is correct either way. Worth confirming which one you
actually intend to use day to day, since that decides where `kubectl apply` actually lands.

## Not yet verified

A live run. Both local contexts are currently blocked by the pre-existing Norton
TLS-interception issue from earlier in this session - see `deploy-llm-blue-green.md`'s
"Verification status" section.
