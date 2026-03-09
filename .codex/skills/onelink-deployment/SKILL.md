---
name: onelink-deployment
description: "Use for Onelink deployment and runtime operations: Docker and compose flows, VM and systemd assets, self-hosted docs, environment configuration, and release-oriented operator guidance."
---

# Onelink Deployment

## Overview

Use this skill when the task is about how Onelink is run, configured, packaged, or documented for operators.

This skill owns deployment assets, runtime config touchpoints, self-hosted docs, and the gap between current operational files and operator-facing documentation.

## Use This Skill When

- editing `deployment/`
- editing `docker/` or `docker-compose*.yaml`
- changing runtime docs under `docs/self-hosted/`
- changing infrastructure-facing environment guidance
- adjusting Sidekiq, Puma, storage, or runtime configuration behavior

## Read First

1. `/Users/akhanbakhitov/Documents/zeroprompt/onelink/AGENTS.md`
2. `/Users/akhanbakhitov/Documents/zeroprompt/onelink/docs/platform/repository-map.mdx`
3. `/Users/akhanbakhitov/Documents/zeroprompt/onelink/docs/contributing-guide/project-operations.mdx`
4. `/Users/akhanbakhitov/Documents/zeroprompt/onelink/docs/self-hosted.mdx`
5. `/Users/akhanbakhitov/Documents/zeroprompt/onelink/docs/self-hosted/deployment/architecture.mdx`

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

- `/Users/akhanbakhitov/Documents/zeroprompt/onelink/docs/platform/repository-map.mdx`
- `/Users/akhanbakhitov/Documents/zeroprompt/onelink/docs/contributing-guide/project-operations.mdx`
- `/Users/akhanbakhitov/Documents/zeroprompt/onelink/docs/self-hosted.mdx`
- `/Users/akhanbakhitov/Documents/zeroprompt/onelink/docs/self-hosted/deployment/architecture.mdx`
