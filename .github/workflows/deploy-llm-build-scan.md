# `deploy-llm.yml` — Step 2: Build + Security Scan

Brief outline of the `build` job added in this step, and what to expect when it runs.

## Actions taken

| Step | What it does |
|---|---|
| Checkout code | Pulls the repo so the Dockerfile/app code are available to build |
| Set up Docker Buildx | Enables the cache backend and multi-stage build features used below |
| Configure AWS credentials | Authenticates the runner to AWS using the `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` secrets set up in Step 1 |
| Docker login (Amazon ECR) | Authenticates the local Docker daemon against the account's ECR registry with a short-lived token |
| Resolve image tag | Builds the full tag `<ecr-registry>/tc-llm:<commit-sha>` so every image traces back to the exact commit it came from |
| Cache Docker layers (`actions/cache`) | Persists `/tmp/.buildx-cache` between runs, keyed on `M1_Dockerfile.template` + `M1_requirements.txt` + `download_model.py` — only invalidates when one of those actually changes |
| Build image | `docker/build-push-action`, `load: true` (so Trivy can see it locally), `push: false` (pushing is a later step) |
| Move cache into place | Buildx writes to a separate `-new` dir; this step swaps it in so the cache doesn't grow unbounded |
| Run Trivy vulnerability scanner | Scans the built image; `severity: CRITICAL,HIGH` + `exit-code: 1` fails the job on any match; `ignore-unfixed: true` skips CVEs with no available patch |
| Upload Trivy results | Publishes the SARIF report to the repo's Security tab, `if: always()` so results show up even when the scan step failed the job |

## Anticipated outcome

- **Clean image**: job succeeds, image is tagged and cached locally on the runner (not yet pushed anywhere), and Trivy results are visible under **Security → Code scanning**.
- **HIGH/CRITICAL vulnerability found**: the Trivy step exits non-zero, the job is marked failed, and nothing proceeds to a deploy step (none exists yet) — but the SARIF upload still runs, so the specific finding is visible in the Security tab for triage rather than just a red X.
- **Rebuild after an app-code-only change**: the Docker layer cache key doesn't include `M1_app.py`, so the cached layers (OS/toolchain, model weights, dependencies) are reused and only the final `COPY M1_app.py` layer rebuilds — same caching behavior already verified directly against `M1_Dockerfile.template`.
- **Missing/invalid AWS credentials**: the "Configure AWS credentials" or "Docker login" step fails early and loudly, before any build time is spent.

## Not yet implemented (next step)

- Push the built, scanned image to ECR
- Deploy job: blue/green rollout, health-check validation, automatic rollback
