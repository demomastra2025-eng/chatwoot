---
name: onelink-deployment
description: "Use for Onelink deployment and runtime operations: Docker and compose flows, VM and systemd assets, self-hosted docs, environment configuration, and release-oriented operator guidance."
---

# Onelink Deployment

## Overview

Use this skill when the task is about how Onelink is run, configured, packaged, or documented for operators.

This skill owns deployment assets, runtime config touchpoints, self-hosted docs, and the gap between current operational files and operator-facing documentation.

All repo paths below are relative to the Onelink repository root.

## Use This Skill When

- editing `deployment/`
- editing `docker/` or `docker-compose*.yaml`
- changing runtime docs under `docs/self-hosted/`
- changing infrastructure-facing environment guidance
- adjusting Sidekiq, Puma, storage, or runtime configuration behavior

## Read First

1. `AGENTS.md`
2. `docs/platform/repository-map.mdx`
3. `docs/contributing-guide/project-operations.mdx`
4. `docs/self-hosted.mdx`
5. `docs/self-hosted/deployment/architecture.mdx`

## Workflow

1. Identify the deployment surface:
   - local dev runtime
   - Docker or compose
   - VM or systemd deployment
   - self-hosted documentation
   - environment or storage configuration
2. Validate the current operator path in code and config files first.
3. Change the runtime files in `onelink`.
4. If operator behavior changed, update the self-hosted docs in `onelink/docs`.
5. Keep the app repo commit and docs repo commit separate.

## Documentation Discipline

- Read the deployment and self-hosted docs before editing.
- If deployment steps, runtime config, infra assumptions, or operator workflow changed, update `docs/` in the same task.
- Keep deployment/config commits in `onelink` and self-hosted docs commits in `docs/`.

## Placement Rules

- VM and system install assets:
  - `deployment/`
- container build and compose:
  - `docker/`, `docker-compose.yaml`, `docker-compose.production.yaml`, `docker-compose.test.yaml`
- runtime configuration:
  - `config/environments/`, `config/puma.rb`, `config/sidekiq.yml`, `config/storage.yml`
- operator docs:
  - `onelink/docs/self-hosted/`

## Deployment Guardrails

- do not describe a deployment path in docs that is not supported by the current files
- do not change operator-facing environment behavior without updating the matching docs
- do not mix local dev conventions with production operator guidance unless the page is clearly labeled

## Verification

- syntax or config validation for touched files
- `docker compose config` when compose files change
- narrow runtime smoke checks when practical
- docs validation if self-hosted docs changed

## Repo Boundary Rule

Deployment code and config live in `onelink`. Operator docs live in `onelink/docs`.

## References

- `docs/platform/repository-map.mdx`
- `docs/contributing-guide/project-operations.mdx`
- `docs/self-hosted.mdx`
- `docs/self-hosted/deployment/architecture.mdx`
