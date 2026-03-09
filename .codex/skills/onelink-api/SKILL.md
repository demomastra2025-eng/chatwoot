---
name: onelink-api
description: "Use for Onelink API work: application, platform, public, and survey endpoints; request and response contracts; Swagger generation; and OpenAPI docs synchronization."
---

# Onelink API

## Overview

Use this skill when the task changes an API contract or the documentation generated from it.

This skill owns controller-to-spec-to-Swagger alignment and the follow-up sync into Mintlify OpenAPI files.

All repo paths below are relative to the Onelink repository root.

## Use This Skill When

- adding or changing endpoints under `api/`, `platform/`, `public/`, or survey surfaces
- changing request params or response payloads
- updating Swagger source files or generated OpenAPI output
- fixing mismatch between runtime API behavior and docs reference

## Read First

1. `AGENTS.md`
2. `docs/platform/current-architecture.mdx`
3. `docs/platform/repository-map.mdx`
4. `docs/contributing-guide/project-operations.mdx`
5. `docs/contributing-guide/apis.mdx`
6. `docs/contributing-guide/api-documentation.mdx`
7. `docs/contributing-guide/platform-apis.mdx`
8. `docs/contributing-guide/docs-repository-workflow.mdx` if docs sync is required

## Workflow

1. Locate the current route, controller, serializer or builder, policy, and request spec.
2. Change runtime behavior in the app repo first.
3. Update request specs and Swagger source files to match the real contract.
4. Run `bundle exec rake swagger:build`.
5. If Mintlify API reference should change, run `./scripts/sync-openapi-from-onelink.sh` from `onelink/docs`.
6. Commit docs-side OpenAPI changes in the docs repo separately from app code.

## Documentation Discipline

- Read the API docs listed above before editing.
- If request or response contracts, auth rules, or generated API reference changed, update `docs/` in the same task.
- Keep runtime API commits in `onelink` and docs/OpenAPI commits in `docs/`.

## Placement Rules

- routes:
  - `config/routes.rb`
- controllers:
  - `app/controllers/api/`, `app/controllers/public/`, `app/controllers/platform/`, `app/controllers/survey/`
- API tests:
  - `spec/requests/` and neighboring request specs
- Swagger:
  - `swagger/`
- Mintlify OpenAPI files:
  - `onelink/docs/openapi/`

## API Guardrails

- do not update Swagger without matching runtime behavior
- do not treat docs-only contract changes as valid if request specs still describe different behavior
- keep account scoping and authorization rules aligned with the endpoint surface
- if a change is primarily feature logic, coordinate with the owning backend or integrations skill

## Verification

- targeted request specs
- `bundle exec rake swagger:build`
- docs-side OpenAPI sync if API reference changed

## Repo Boundary Rule

Runtime API code lives in `onelink`. Mintlify API reference files live in `onelink/docs`.

## References

- `docs/contributing-guide/apis.mdx`
- `docs/contributing-guide/api-documentation.mdx`
- `docs/contributing-guide/platform-apis.mdx`
- `docs/contributing-guide/project-operations.mdx`
- `docs/contributing-guide/docs-repository-workflow.mdx`
