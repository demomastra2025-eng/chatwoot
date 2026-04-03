---
name: onelink-deployment
description: "Use for Onelink deployment and runtime operations: Docker and compose flows, VM and systemd assets, environment configuration, release-oriented operator guidance, and internal cloud operations notes."
---

# Onelink Deployment

Use this skill when the task is about how One Link is run, configured, packaged, or documented for internal operators.

This skill owns deployment assets, runtime config touchpoints, and the gap between current operational files and internal cloud-operations guidance.

All repo paths below are relative to the One Link repository root.

## Use This Skill When

- editing `deployment/`
- editing `docker/` or `docker-compose*.yaml`
- changing infrastructure-facing environment guidance
- adjusting Sidekiq, Puma, storage, or runtime configuration behavior
- documenting internal operator or release flow

## Read First

1. `AGENTS.md`
2. `docs/internal/architecture-overview.mdx`
3. `docs/internal/repository-structure.mdx`
4. `docs/internal/testing-and-tooling.mdx`

## Workflow

1. Identify the deployment surface:
   - local dev runtime
   - Docker or compose
   - VM or systemd deployment
   - environment or storage configuration
   - internal operator documentation
2. Validate the current operator path in code and config files first.
3. Change the runtime files in `onelink`.
4. If operator behavior changed, update the matching internal guidance in `docs/internal/` or `AGENTS.md`.
5. Keep app repo and docs repo commits separate when both changed.

## Documentation Discipline

- Do not expose internal deployment or cloud-operations details in public docs.
- If deployment steps, runtime config, infra assumptions, or operator workflow changed, update internal docs in the same task.

## Placement Rules

- VM and system install assets:
  - `deployment/`
- container build and compose:
  - `docker/`
  - `docker-compose.yaml`
  - `docker-compose.production.yaml`
  - `docker-compose.test.yaml`
- runtime configuration:
  - `config/environments/`
  - `config/puma.rb`
  - `config/sidekiq.yml`
  - `config/storage.yml`
- internal operator docs:
  - `AGENTS.md`
  - `onelink/docs/internal/`

## Deployment Guardrails

- do not describe a deployment path in docs that is not supported by the current files
- do not change operator-facing environment behavior without updating the matching internal guidance
- do not mix local dev conventions with production operator guidance unless the target page is clearly internal

## Verification

- syntax or config validation for touched files
- `docker compose config` when compose files change
- narrow runtime smoke checks when practical

## Repo Boundary Rule

Deployment code and config live in `onelink`. Internal operator docs live in `onelink/docs/internal` and repo notes such as `AGENTS.md`.

## References

- `docs/internal/architecture-overview.mdx`
- `docs/internal/repository-structure.mdx`
- `docs/internal/testing-and-tooling.mdx`
