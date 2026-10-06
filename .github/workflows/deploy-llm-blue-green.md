# `deploy-llm.yml` — Step 3: Push, Blue-Green Deploy, Rollback, Notify

Brief outline of the `deploy` job. **Reconfigured**: this originally targeted AWS
(ECR/ALB/SSM) — see `deploy-llm-local-k8s.md` for why and what changed. Everything below
describes the *current* kubectl-based logic.

> **Requires a self-hosted runner.** GitHub-hosted runners have no network path to a
> cluster running on your own machine's localhost, and with no container registry in the
> picture, a hosted `build` job would have nowhere to hand the image to either. Both
> `build` and `deploy` are pinned to `runs-on: self-hosted` for this reason.

## 1. Push to Docker Hub, pull via an imagePullSecret

The `build` job tags the image as `joecoursera/tc-llm:<commit-sha>` and pushes it after
the Trivy gate passes, same ordering as before (build local → scan → push only on
success):

```yaml
- name: Push image to Docker Hub
  run: docker push ${{ steps.image.outputs.tag }}
```

The `deploy` job doesn't need to load anything into the cluster anymore - kubelet pulls
the tag directly. It does need credentials in case the repo is private, built from this
same machine's existing `docker login` session:

```yaml
- name: Create/update Docker Hub imagePullSecret
  run: |
    kubectl create secret generic dockerhub-regcred \
      --from-file=.dockerconfigjson="${HOME}/.docker/config.json" \
      --type=kubernetes.io/dockerconfigjson \
      --namespace "$K8S_NAMESPACE" \
      --dry-run=client -o yaml | kubectl apply -f -
```

**Why reuse the host's docker config instead of new secrets:** this machine is already
logged in to Docker Hub per the task that introduced this; copying that same credential
into the cluster avoids asking for a second, separate login just for Kubernetes to use.
**Expected outcome:** on a clean Trivy scan, the image lands on Docker Hub under
`joecoursera/tc-llm:<sha>`; the Deployments (`k8s/deployment-blue.yaml`/`-green.yaml`)
reference `imagePullSecrets: [dockerhub-regcred]`, so `kubectl set image` + a normal
registry pull is all that's needed to get the new version running - no `kind load`
branching logic at all anymore.

## 2. Blue-green deploy with health check validation

New `deploy` job, `needs: build`. Active/idle color is tracked in a Kubernetes ConfigMap
(works even before the Service has ever been flipped once):

```yaml
- name: Determine active and target colors
  id: colors
  run: |
    ACTIVE=$(kubectl get configmap tc-llm-active-color -n "$K8S_NAMESPACE" \
      -o jsonpath='{.data.color}' 2>/dev/null || echo blue)
    if [ "$ACTIVE" = "blue" ]; then TARGET=green; else TARGET=blue; fi
    echo "active=$ACTIVE" >> "$GITHUB_OUTPUT"
    echo "target=$TARGET" >> "$GITHUB_OUTPUT"
```

Health validation happens **twice** — before *and* after the traffic switch:

```yaml
- name: Validate target color health (pre-flip)
  run: |
    kubectl rollout status deployment/tc-llm-${{ steps.colors.outputs.target }} \
      -n "$K8S_NAMESPACE" --timeout=120s
```

```yaml
- name: Switch Service traffic to target color
  id: switch
  run: |
    kubectl patch service tc-llm -n "$K8S_NAMESPACE" \
      -p "{\"spec\":{\"selector\":{\"color\":\"${{ steps.colors.outputs.target }}\"}}}"
```

```yaml
- name: Post-flip smoke test
  run: |
    kubectl port-forward service/tc-llm 18080:80 -n "$K8S_NAMESPACE" &
    PF_PID=$!; trap 'kill $PF_PID 2>/dev/null' EXIT; sleep 3
    for i in $(seq 1 15); do
      CODE=$(curl -s -o /dev/null -w '%{http_code}' http://localhost:18080/health/ready)
      [ "$CODE" = "200" ] && exit 0
      sleep 5
    done
    exit 1
```

**Why twice:** `kubectl rollout status` blocking on Ready pods (pre-flip) means the
container's own `readinessProbe` against `/health/ready` passed — but that's still not
the same guarantee as a real request through the Service succeeding (post-flip), which is
what the port-forward + curl step actually exercises.
**Expected outcome:** pre-flip failure aborts before the Service selector is ever
touched; post-flip failure means traffic *was* switched and something's still wrong —
that's what rollback (next section) exists for.

## 3. Automatic rollback on health check failure

```yaml
- name: Rollback to previous color on failure
  if: failure() && steps.switch.outcome == 'success'
  run: |
    kubectl patch service tc-llm -n "$K8S_NAMESPACE" \
      -p "{\"spec\":{\"selector\":{\"color\":\"${{ steps.colors.outputs.active }}\"}}}"
    kubectl scale deployment/tc-llm-${{ steps.colors.outputs.target }} --replicas=0 -n "$K8S_NAMESPACE"
```

**Why the condition:** `failure()` is true if any earlier step failed; AND-ing it with
`steps.switch.outcome == 'success'` means rollback only fires when traffic was *actually
switched* — a pre-flip failure has nothing to undo, so this correctly stays dormant then.
**Expected outcome:** the Service selector flips straight back to the previously-active
color, and the bad target color is scaled to 0 (freeing resources on the 2-node cluster).
The active-color ConfigMap is only ever updated on success, so a rolled-back run leaves it
unchanged — the next run retries the same target color again.

## 4. Deployment status notification

```yaml
- name: Post deployment status summary
  if: always()
  run: |
    {
      echo "### TC-LLM Deployment - ${{ job.status }}"
      echo "- Namespace: $K8S_NAMESPACE"
      echo "- Image: ${{ needs.build.outputs.image_tag }}"
    } >> "$GITHUB_STEP_SUMMARY"

- name: Notify Slack (optional)
  if: always()
  env:
    SLACK_WEBHOOK_URL: ${{ secrets.SLACK_WEBHOOK_URL }}
  run: |
    if [ -z "$SLACK_WEBHOOK_URL" ]; then exit 0; fi
    curl -s -X POST -H 'Content-type: application/json' \
      --data "{\"text\":\"TC-LLM local k8s deploy: ${{ job.status }}\"}" \
      "$SLACK_WEBHOOK_URL"
```

**Why two channels:** `$GITHUB_STEP_SUMMARY` needs zero configuration and always works —
it's the guaranteed notification. Slack is additive and self-disables (exits 0, no error)
if `SLACK_WEBHOOK_URL` isn't configured as a secret yet.
**Expected outcome:** every run — success, failure, or rollback — leaves a markdown
summary on the run page. Once `SLACK_WEBHOOK_URL` is added under *Settings → Secrets and
variables → Actions*, the same status also posts to Slack with no code change.

## Verification status

Validated by careful construction and static YAML checks (parses cleanly, all step
references resolve correctly), **not** by a live run. A real end-to-end test was
attempted against both the `docker-desktop` and `kind-desktop` local contexts and both are
currently blocked by a pre-existing Norton TLS-interception issue on this machine
(`x509: certificate signed by unknown authority`) unrelated to this workflow's logic —
needs the Norton firewall exclusion identified earlier in this session before either
`kubectl` or a self-hosted runner executing this workflow can actually reach the cluster.

## Not yet implemented (next step)

- Register and verify a self-hosted GitHub Actions runner on the docker-desktop/kind machine
- Resolve the Norton TLS interception so `kubectl` (and this workflow) can reach the cluster
- A real live run, once the above two are done
