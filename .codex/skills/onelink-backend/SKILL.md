---
name: onelink-backend
description: "Use for Rails backend work in Onelink: models, services, controllers, jobs, policies, listeners, account-scoped behavior, enterprise overlay checks, and backend verification."
---

# Onelink Backend

Use this skill when the task is primarily backend implementation inside the main `onelink` application repository.

This skill owns placement and execution decisions for Rails-side work. Keep changes aligned with current One Link entities, account scoping, service patterns, and the active `enterprise/` extension layer.

All repo paths below are relative to the One Link repository root.

## Use This Skill When

- changing `app/models/`, `app/services/`, `app/controllers/`, `app/jobs/`, `app/listeners/`, `app/policies/`, or `app/presenters/`
- adding or refactoring account-scoped business logic
- extending communication, CRM, scheduling, automation, reporting, or omnichannel flows
- changing backend behavior that may have `enterprise/` companions

## Read First

1. `AGENTS.md`
2. `docs/internal/architecture-overview.mdx`
3. `docs/internal/backend-architecture.mdx`
4. `docs/internal/entity-reference.mdx`
5. `docs/internal/data-model-and-db.mdx`
6. `docs/internal/permissions-and-access.mdx`
7. `docs/internal/testing-and-tooling.mdx`

## Workflow

1. Identify the core entity and request flow.
2. Search both `app/` and `enterprise/` before editing shared behavior.
3. Decide whether the change is:
   - shared platform behavior
   - workspace-specific configuration behavior
   - integration-specific behavior
4. Reuse native entities first:
   - `Account`
   - `AccountUser`
   - `Inbox`
   - `Contact`
   - `Company`
   - `Conversation`
   - `Message`
   - `Note`
   - `Label`
   - `Team`
   - `Macro`
   - `AutomationRule`
   - `Integrations::App`
   - `Integrations::Hook`
   - Captain entities
   - CRM entities
   - scheduling entities
5. Place the smallest coherent change in the existing model, service, controller, or policy path before inventing a new abstraction.
6. If request or response behavior changes, coordinate with `onelink-api`.
7. Verify with the narrowest meaningful backend command.

## Documentation Discipline

- Update public docs when user-visible behavior or entity meaning changed.
- Update internal docs when architecture, subsystem flow, data modeling, or access rules changed.
- Keep docs commits separate in `docs/` when documentation changes are required.

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
  - `enterprise/app/`
  - `enterprise/lib/`
  - enterprise extension modules

Prefer existing namespaces and feature folders over new top-level folders.

## Backend Guardrails

- do not assume docs are more current than code
- do not bypass account scoping
- do not hard-fork enterprise behavior into OSS files when extension points already exist
- do not add new models until existing entities, custom fields, notes, labels, teams, automations, integrations, or Captain surfaces have been ruled out
- do not reintroduce domain-zone branching when access, configuration, or fields already solve the requirement

## Verification

- targeted RSpec for the touched files or request flow
- request spec plus policy path for new backend endpoints
- Swagger build if API contracts changed
- narrow manual smoke check only if automated coverage is not practical

## Repo Boundary Rule

This skill normally edits only `onelink`. If docs also need updates, keep the docs commit separate in `onelink/docs`.

## References

- `docs/internal/backend-architecture.mdx`
- `docs/internal/entity-reference.mdx`
- `docs/internal/data-model-and-db.mdx`
- `docs/internal/permissions-and-access.mdx`
- `docs/internal/testing-and-tooling.mdx`
