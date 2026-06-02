# DevOps Agent Rules

Agent-agnostic safety guardrails for DevOps work. Reference from a project's `CLAUDE.md`, paste into a system prompt, or include as context when working in any DevOps repo.

## Safety — non-negotiable

- NEVER run destructive commands (`delete`, `destroy`, `rm -rf`, `drop`, `truncate`) without explicit user confirmation.
- NEVER auto-approve `terraform apply`, `kubectl apply`, `helm upgrade`, or any mutation in production.
- NEVER hardcode secrets, passwords, API keys, or tokens in code. Always use secret management (K8s Secrets, AWS Secrets Manager, Vault, env vars from CI).
- NEVER echo, print, or log secret values. Only reference secret names, ARNs, or paths.
- ALWAYS verify the target environment (prod/staging/dev) before suggesting any write operation.
- ALWAYS check `kubectl config current-context` before running any kubectl command.
- ALWAYS check `aws sts get-caller-identity` before running any AWS command.
- ALWAYS prefer `--dry-run=client` or `--dry-run=server` for kubectl mutations.
- ALWAYS prefer `terraform plan` before `terraform apply`.

## Read-only first

- When debugging or investigating, default to read-only commands (`get`, `describe`, `list`, `logs`, `events`, `plan`, `show`).
- Only suggest write operations after the investigation is complete and the user has reviewed the findings.
- If a command could have side effects, warn the user explicitly before running it.

## Infrastructure changes

- For Terraform: always show the plan output and explain what will change before suggesting apply.
- For Kubernetes: prefer declarative (`kubectl apply -f`) over imperative (`kubectl create`, `kubectl run`) for anything persistent.
- For Helm: show `helm diff upgrade` or `--dry-run` output before actual upgrade.
- For Docker: never suggest `docker system prune` without confirming the user wants to remove unused resources.
- For CI/CD: never suggest pipeline config changes without explaining the blast radius.

## Code quality

- Follow existing code style and conventions in the repo. Don't impose new patterns without discussion.
- When modifying IaC, always consider state implications (will this cause a replacement? will this force a new resource?).
- When modifying pipelines, consider all branches — not just main/master.
- When modifying Dockerfiles, preserve the layer cache order.
- Pin versions: base images, package versions, tool versions. Never use `latest` in production contexts.

## Communication

- When uncertain, say "I'm not sure" and suggest how to verify.
- When a command fails, diagnose before retrying. Don't blindly retry the same command.
- When multiple solutions exist, briefly list the options with trade-offs before implementing one.
- Provide copy-pastable commands — no pseudocode for CLI operations.

## GitOps and ArgoCD awareness

- If ArgoCD or Flux manages resources in a cluster, warn that manual `kubectl apply` changes will be reverted by the controller.
- Prefer suggesting changes to git source (manifests, values files) over live cluster edits.
- When modifying Helm values managed by ArgoCD, suggest the change in the git repo, not `helm upgrade`.
- Check for ArgoCD Application resources before suggesting manual Helm or kubectl changes.

## Monitoring and observability

- Never modify alerting rules without explaining the impact on on-call notification flow.
- When changing Prometheus rules, validate PromQL syntax before suggesting apply.
- When modifying log retention, warn about compliance and audit requirements.
- Never disable alerts as a "fix" for noisy alerts — suggest tuning thresholds or adding filters instead.

## Multi-repo coordination

- When a change spans multiple repos (e.g., service repo + build-seed + shared library), clearly list all repos that need changes and the deployment order.
- For Jenkins shared library changes, remind that `BRANCH_CONFIG.BUILD_SEED` must point to the correct branch.
- For infrastructure changes, identify if the change requires a coordinated deployment (e.g., Terraform before service deploy).

## Git hygiene

- Check `git status` and `git diff` before suggesting commits.
- Never force-push to shared branches without explicit confirmation.
- Suggest meaningful commit messages that explain WHY, not just WHAT.
- When creating branches, follow the repo's naming convention.
- When working across repos, suggest consistent branch names for related changes.
