---
name: onelink-integrations
description: "Use for Onelink omnichannel and external integration work: channels, inbox providers, hooks, provider-specific services, callbacks, and integration lifecycle behavior."
---

# Onelink Integrations

Use this skill when the task is about how One Link talks to external channels, providers, and connected systems.

This skill owns provider-specific placement, channel lifecycle behavior, inbox integration rules, and the distinction between integration definitions, installed hooks, and AI tools.

All repo paths below are relative to the One Link repository root.

## Use This Skill When

- changing channel providers such as WhatsApp, Instagram, Facebook, Telegram, Line, TikTok, email, SMS, or website chat
- changing inbox or channel setup logic
- changing `Integrations::App` or `Integrations::Hook` behavior
- editing callback, webhook, or provider-specific service flows
- adding or fixing external system connectivity

## Read First

1. `AGENTS.md`
2. `docs/platform/integrations-architecture.mdx`
3. `docs/platform/communication-workflows.mdx`
4. `docs/internal/automation-and-integrations.mdx`
5. `docs/internal/communication-core.mdx`
6. `docs/internal/api-and-routes.mdx`
7. the relevant provider code paths

## Workflow

1. Identify the integration type:
   - channel provider
   - webhook or callback flow
   - installed integration hook
   - integration catalog entry
2. Inspect existing models, services, controllers, workers, and provider folders before creating new structures.
3. Keep the distinction explicit:
   - `Integrations::App` = integration capability or definition
   - `Integrations::Hook` = installed integration instance
   - `Captain::CustomTool` = AI tool surface, not a general integration lifecycle
4. Search `enterprise/` for overlays before changing shared provider behavior.
5. If request or response contracts change, coordinate with `onelink-api`.

## Documentation Discipline

- If provider behavior, message constraints, setup model, or operator flow changed, update docs in the same task.
- Keep public docs focused on product behavior and integrator setup.
- Keep internal docs focused on runtime callbacks, provider contracts, and architecture.

## Placement Rules

- provider services:
  - `app/services/` and provider subfolders
- channel and integration models:
  - `app/models/channel/`
  - `app/models/integrations/`
  - related inbox models
- callbacks and webhooks:
  - relevant controllers under `app/controllers/`
- provider docs:
  - public docs under `onelink/docs/platform/` and `onelink/docs/integrators/`
  - internal docs under `onelink/docs/internal/`

## Integration Guardrails

- do not invent a new provider abstraction if an existing service pattern already matches
- do not collapse `Integrations::Hook` and `Captain::CustomTool` into one concept
- do not change message or attachment behavior without checking existing provider constraints
- do not assume all channels support the same reply, status, or attachment features

## Verification

- targeted service, request, or model specs
- provider-specific smoke checks where practical
- docs updates when setup or operator behavior changed

## Repo Boundary Rule

Integration code lives in `onelink`. Integration docs live in `onelink/docs`.

## References

- `docs/platform/integrations-architecture.mdx`
- `docs/platform/communication-workflows.mdx`
- `docs/internal/automation-and-integrations.mdx`
- `docs/internal/communication-core.mdx`
