---
name: onelink-integrator
description: Use for partner and customer integrations against One Link Cloud APIs, including surface selection, authentication model, endpoint discovery, webhook design, and implementation planning from the external integrator perspective.
argument-hint: "[integration-goal]"
---

# One Link Integrator

Use this skill when the task is to integrate with One Link Cloud from the outside.

This skill is for API consumers, partner engineers, technical customer teams, and Claude Code sessions acting on their behalf. It is not for changing One Link runtime code.

If the skill is invoked directly, treat `$ARGUMENTS` as the integration goal, business question, or endpoint-discovery request.

## Use This Skill When

- choosing between Application, Client, and Platform APIs
- designing a sync or webhook integration with One Link Cloud
- building a custom chat client on top of the client API
- mapping business objects to One Link resource groups
- drafting cURL requests or implementation plans for external systems
- debugging auth, scope, or path confusion from the integrator side

## Read First

1. `references/api-surfaces.md`
2. `references/resource-groups.md`
3. `references/events-and-patterns.md`
4. `references/usage-playbook.md`
5. `references/openapi-discovery.md` when exact path or contract details are needed

## Workflow

1. Classify the integration surface:
   - Application API
   - Client API
   - Platform API
2. Confirm the authentication owner and token model.
3. Map the business object to the closest One Link resource group.
4. Decide whether the flow should be:
   - request-response only
   - webhook-driven
   - webhook plus write-back
5. If exact contracts are needed, inspect the current OpenAPI files or UI network flow.
6. Produce:
   - recommended API surface
   - auth model
   - path candidates
   - webhook plan
   - implementation sequence
   - open questions or assumptions

## Deliverable Standard

A good answer from this skill should clearly state:

- which API surface to use
- which token and scope model to use
- which resource group or path family to start with
- whether webhooks are needed
- what to verify in the current API reference before coding

## Guardrails

- do not default to Platform API when Application API is enough
- do not expose workspace tokens in client-side code
- do not assume every resource is fully represented in every OpenAPI file
- do not assume CRM or other business modules have stable path shapes unless the current reference confirms them
- treat public docs as guidance and current OpenAPI as the contract when available
- if docs and API reference disagree, prefer the current API reference and ask the user to confirm the affected endpoint

## Optional Local Contract Lookup

If the user has the current OpenAPI files locally, use `references/openapi-discovery.md` and `scripts/search_openapi.py` to find matching path families and operation summaries.

## References

- `references/api-surfaces.md`
- `references/resource-groups.md`
- `references/events-and-patterns.md`
- `references/usage-playbook.md`
- `references/openapi-discovery.md`
