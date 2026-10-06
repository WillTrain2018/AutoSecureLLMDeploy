# `deploy-llm.yml` — what it does

Brief outline of the TC-LLM deploy pipeline. Step 1 of the build-out: triggers and
registry credential env vars only.

## Triggers

- **`push`** to `main`, scoped to `AutoSecureLLM_Module1_Deployment/Module1_Deployment/**` — redeploy on app/infra code changes.
- **`repository_dispatch`** (`model-artifact-updated`) — redeploy when a new model artifact lands in the model bucket, independent of any code change. Fired externally via the GitHub API (e.g. a Lambda/EventBridge rule on S3 `PutObject`).
- **`workflow_dispatch`** — manual run, with an `environment` choice (`dev`/`staging`/`prod`).

## Environment variables

- `AWS_REGION`, `ECR_REPOSITORY` — container registry coordinates, matching `M1_main.tf`.
- `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` — forwarded from GitHub repo/environment secrets (**Settings > Secrets and variables > Actions**); never hardcoded.

## Jobs (this step)

- `setup` — placeholder only: prints the trigger context, echoes the model payload on a `repository_dispatch`, and warns if registry credentials aren't configured yet.

## Not yet implemented (future steps)

- Docker build + push to ECR
- Trivy vulnerability scanning (fail on CRITICAL/HIGH)
- Blue/green deploy, health-check validation, automatic rollback
