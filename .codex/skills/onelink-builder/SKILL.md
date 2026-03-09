---
name: onelink-builder
description: "Use for broad or cross-cutting work in the Onelink project at /Users/akhanbakhitov/Documents/zeroprompt/onelink. This is the coordinator skill for choosing the correct Onelink surface and specialized skill across backend, frontend, API, integrations, Captain/AI, documentation, deployment, and repo-boundary workflows."
---

# Onelink Builder

## Overview

Use this skill when the task is specific to the Onelink project but is too broad to start directly in one implementation surface.

This skill is the coordinator. It should:

- classify the task
- identify the owning repo and directory
- load the minimum set of project docs needed
- select the correct specialized skill when the task becomes narrow

If the task is already clearly backend-only, frontend-only, docs-only, and so on, use the specialized skill directly instead of loading this skill first.

## Use This Skill When

Use `onelink-builder` when the user asks for any of the following:

- a project-wide or architectural change
- a task that spans app code, docs, and deployment
- a task where the correct repo or directory is not obvious
- a task that may touch more than one specialized skill surface
- a request to understand how Onelink is structured before editing
- a request to decide which project skill should own the work

## Skill Family

`onelink-builder` coordinates this skill family:

- `onelink-backend`
  - Rails models, services, controllers, jobs, policies, and shared backend workflows
- `onelink-frontend`
  - dashboard, widget, portal, survey, SDK, state management, and reusable UI
- `onelink-api`
  - API contracts, request/response behavior, Swagger, and OpenAPI docs sync
- `onelink-integrations`
  - inbox channels, hooks, providers, and omnichannel external systems
- `onelink-captain`
  - Captain, copilot, documents, custom tools, and AI-connected flows
- `onelink-documentation`
  - Mintlify docs structure, docs content, docs navigation, and docs repo workflow
- `onelink-deployment`
  - runtime operations, Docker, self-hosted docs, deployment scripts, and operator guidance

## Read First

For broad tasks, build context in this order:

1. `/Users/akhanbakhitov/Documents/zeroprompt/onelink/AGENTS.md`
2. `/Users/akhanbakhitov/Documents/zeroprompt/onelink/docs/platform/current-architecture.mdx`
3. `/Users/akhanbakhitov/Documents/zeroprompt/onelink/docs/platform/repository-map.mdx`
4. `/Users/akhanbakhitov/Documents/zeroprompt/onelink/docs/contributing-guide/project-operations.mdx`
5. `/Users/akhanbakhitov/Documents/zeroprompt/onelink/docs/contributing-guide/ai-agent-operating-model.mdx`
6. `/Users/akhanbakhitov/Documents/zeroprompt/onelink/docs/contributing-guide/skill-map.mdx`

Load target-direction pages only when current-state docs and concrete code are not enough.

## Coordinator Workflow

1. Classify the task before editing anything:
   - backend
   - frontend
   - api
   - integrations
   - captain/ai
   - docs
   - deployment
   - mixed
2. Identify the owning repo:
   - `onelink` for product code, specs, routes, runtime config, and deployment assets
   - `onelink/docs` for Mintlify docs content and OpenAPI files
   - `$CODEX_HOME/skills` for local skill definitions
3. Identify the primary directories to inspect.
4. Hand off to the matching specialized skill if the task is now narrow enough.
5. Keep commits separate when a mixed task touches more than one repo.

## Repo Boundary Rules

- `docs/` inside `onelink` is a git submodule backed by `demomastra2025-eng/onelink-docs`.
- Read and edit `onelink/docs` as local files, but commit docs content in the docs repo first.
- The parent `onelink` repo only stores the updated submodule pointer after docs changes.
- Versioned project skill files live under `/Users/akhanbakhitov/Documents/zeroprompt/onelink/.codex/skills`.
- Installed runtime skill files live under `/Users/akhanbakhitov/.codex/skills`.
- If a skill changes, keep the project copy and the installed Codex copy in sync.

## Project Rules

- Treat current code as the source of truth for what exists today.
- Treat target-direction docs as intent, not proof of runtime implementation.
- Search both `app/` and `enterprise/` before changing shared behavior.
- Prefer native entities and existing extension points before introducing new abstractions.
- Use the narrowest verification that meaningfully covers the touched surface.
- Do not mix unrelated staged files into a task commit just because they are already staged.
- After changing versioned skills in `onelink/.codex/skills`, sync them into Codex home with `./.codex/scripts/sync-skills.sh to-codex-home`.

## Handoff Standard

At the end of a broad task, leave enough context for a human or another agent to answer:

- what changed
- which repo owns the change
- which specialized skill was used
- what was verified
- whether `onelink` still needs a docs submodule pointer update

## References

- `/Users/akhanbakhitov/.codex/skills/onelink-builder/references/architecture.md`
- `/Users/akhanbakhitov/.codex/skills/onelink-builder/references/workflow.md`
- `/Users/akhanbakhitov/.codex/skills/onelink-builder/references/docs-map.md`
