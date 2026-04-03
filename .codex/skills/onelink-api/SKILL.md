---
name: onelink-api
description: "Use for Onelink API work: application, platform, public, and survey endpoints; request and response contracts; Swagger generation; and OpenAPI docs synchronization."
---

# Onelink API

Use this skill when the task changes a real API contract or the documentation generated from it.

This skill owns route-to-controller-to-spec-to-Swagger alignment and the follow-up sync into the Mintlify OpenAPI files.

All repo paths below are relative to the One Link repository root.

## Use This Skill When

- adding or changing endpoints under `api/`, `platform/`, `public/`, or survey surfaces
- changing request params, auth rules, or response payloads
- updating Swagger source files or generated OpenAPI output
- fixing mismatch between runtime API behavior and API docs

## Read First

1. `AGENTS.md`
2. `docs/internal/api-and-routes.mdx`
3. `docs/internal/testing-and-tooling.mdx`
4. `docs/api-reference/introduction.mdx`
5. `docs/integrators/authentication-and-api-model.mdx`
6. `docs/integrators/api-resource-map.mdx`
7. `docs/AGENTS.md` if docs sync is required

## Workflow

1. Locate the current route, controller, serializer or builder, policy, and request spec.
2. Change runtime behavior in the app repo first.
3. Update request specs and Swagger source files to match the real contract.
4. Run `bundle exec rake swagger:build`.
5. If Mintlify API reference should change, run `./scripts/sync-openapi-from-onelink.sh` from `onelink/docs`.
6. Keep app changes in `onelink` and generated OpenAPI changes in `docs/`.

## Documentation Discipline

- If request or response contracts, auth rules, or generated API reference changed, update docs in the same task.
- Update public API docs when integrator-facing behavior changed.
- Update internal API docs when route topology, ownership, or subsystem mapping changed.

## Placement Rules

- routes:
  - `config/routes.rb`
- controllers:
  - `app/controllers/api/`
  - `app/controllers/public/`
  - `app/controllers/platform/`
  - `app/controllers/survey/`
- API tests:
  - `spec/requests/`
- Swagger:
  - `swagger/`
- Mintlify OpenAPI files:
  - `onelink/docs/openapi/`

## API Guardrails

- do not update Swagger without matching runtime behavior
- do not treat docs-only contract changes as valid if request specs still describe different behavior
- keep account scoping and authorization rules aligned with the endpoint surface
- if a change is primarily feature logic, coordinate with `onelink-backend` or `onelink-integrations`

## Verification

- targeted request specs
- `bundle exec rake swagger:build`
- docs-side OpenAPI sync if API reference changed

## Repo Boundary Rule

Runtime API code lives in `onelink`. Mintlify API reference files live in `onelink/docs`.

## References

- `docs/internal/api-and-routes.mdx`
- `docs/internal/testing-and-tooling.mdx`
- `docs/api-reference/introduction.mdx`
- `docs/integrators/authentication-and-api-model.mdx`
- `docs/integrators/api-resource-map.mdx`
