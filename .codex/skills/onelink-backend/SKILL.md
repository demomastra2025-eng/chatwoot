---
name: onelink-backend
description: "Use for Rails backend work in Onelink: models, services, controllers, jobs, policies, listeners, account-scoped behavior, enterprise overlay checks, and backend verification."
---

# Onelink Backend

## Overview

Use this skill when the task is primarily backend implementation inside the main `onelink` application repository.

This skill owns placement and execution decisions for Rails-side work. It should keep changes aligned with existing Onelink entities, service patterns, account scoping, and the active `enterprise/` extension layer.

All repo paths below are relative to the Onelink repository root.

## Use This Skill When

- changing `app/models/`, `app/services/`, `app/controllers/`, `app/jobs/`, `app/listeners/`, `app/policies/`, or `app/presenters/`
- adding or refactoring account-scoped business logic
- extending CRM-adjacent workflows
- touching backend parts of scheduling, automation, reporting, or omnichannel features
- changing backend behavior that may have `enterprise/` companions

## Read First

1. `AGENTS.md`
2. `docs/platform/current-architecture.mdx`
3. `docs/platform/repository-map.mdx` if placement is unclear
4. `docs/contributing-guide/backend-agent-playbook.mdx`
5. `docs/contributing-guide/backend-feature-template.mdx`
6. `docs/contributing-guide/implementation-examples-map.mdx`
7. `docs/contributing-guide/testing-strategy-for-agents.mdx`

## Workflow

1. Identify the core entity and request flow.
2. Search both `app/` and `enterprise/` before editing shared behavior.
3. Decide whether the change is:
   - shared platform behavior
   - domain-specific behavior
   - tenant-specific configuration
4. Reuse native entities first:
   - `Account`, `Contact`, `Company`, `Inbox`, `Conversation`, `Message`, `Note`, `Label`, `Team`, `Macro`, `AutomationRule`, `Integrations::App`, `Integrations::Hook`, `Captain`
5. Place the smallest coherent change in the existing service or controller path before inventing a new abstraction.
6. If request or response behavior changes, coordinate with `onelink-api`.
7. Verify with the narrowest meaningful backend command.

## Documentation Discipline

- Read the backend docs listed above before editing.
- If backend behavior, entity meaning, API payloads, access rules, or operator workflow changed, update `docs/` in the same task.
- Keep the docs commit separate in `docs/` when documentation changes are required.

## Placement Rules

- models and domain behavior:
  - `app/models/`
- request orchestration and feature logic:
  - `app/services/`
- HTTP and API handling:
  - `app/controllers/`
- background execution:
  - `app/jobs/`
- authorization:
  - `app/policies/`
- enterprise-only or extension behavior:
  - `enterprise/app/`, `enterprise/lib/`, or enterprise extension modules

Prefer existing namespaces and feature folders over new top-level folders.

## Backend Guardrails

- do not assume roadmap entities already exist; verify in code first
- do not treat target-direction docs as proof of runtime implementation
- do not bypass account scoping
- do not hard-fork enterprise behavior into OSS files when extension points already exist
- do not add new models until existing entities, custom attributes, notes, labels, teams, automations, integrations, or Captain surfaces have been ruled out

## Verification

- targeted RSpec for the touched files or request flow
- request spec plus policy path for new backend endpoints
- Swagger build if API contracts changed
- narrow manual smoke check only if automated coverage is not practical

## Repo Boundary Rule

This skill normally edits only `onelink`. If docs also need updates, keep the docs commit separate in `onelink/docs`.

## References

- `docs/platform/current-architecture.mdx`
- `docs/contributing-guide/backend-agent-playbook.mdx`
- `docs/contributing-guide/backend-feature-template.mdx`
- `docs/contributing-guide/implementation-examples-map.mdx`
- `docs/contributing-guide/testing-strategy-for-agents.mdx`
