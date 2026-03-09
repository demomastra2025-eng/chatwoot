---
name: onelink-integrations
description: "Use for Onelink omnichannel and external integration work: channels, inbox providers, hooks, provider-specific services, callbacks, and integration lifecycle behavior."
---

# Onelink Integrations

## Overview

Use this skill when the task is about how Onelink talks to external channels, providers, and connected systems.

This skill owns provider-specific placement, channel lifecycle behavior, inbox integration rules, and the distinction between integration definitions, installed hooks, and AI tools.

## Use This Skill When

- changing channel providers such as WhatsApp, Instagram, Facebook, Telegram, Line, TikTok, email, SMS, or website chat
- changing inbox/channel setup logic
- changing `Integrations::App` or `Integrations::Hook` behavior
- editing callback, webhook, or provider-specific service flows
- adding or fixing external system connectivity

## Read First

1. `/Users/akhanbakhitov/Documents/zeroprompt/onelink/AGENTS.md`
2. `/Users/akhanbakhitov/Documents/zeroprompt/onelink/docs/platform/current-architecture.mdx`
3. `/Users/akhanbakhitov/Documents/zeroprompt/onelink/docs/platform/integrations-architecture.mdx`
4. `/Users/akhanbakhitov/Documents/zeroprompt/onelink/docs/platform/repository-map.mdx`
5. `/Users/akhanbakhitov/Documents/zeroprompt/onelink/docs/contributing-guide/implementation-examples-map.mdx`
6. the relevant integration setup page under `contributing-guide/` or `self-hosted/` when one exists

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

## Placement Rules

- provider services:
  - `app/services/` and provider subfolders
- channel and integration models:
  - `app/models/channel/`, `app/models/integrations/`, related inbox models
- callbacks and webhooks:
  - relevant controllers under `app/controllers/`
- provider docs:
  - `onelink/docs/contributing-guide/` or `onelink/docs/self-hosted/`

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

Integration code lives in `onelink`. Integration setup and operator docs live in `onelink/docs`.

## References

- `/Users/akhanbakhitov/Documents/zeroprompt/onelink/docs/platform/integrations-architecture.mdx`
- `/Users/akhanbakhitov/Documents/zeroprompt/onelink/docs/platform/current-architecture.mdx`
- `/Users/akhanbakhitov/Documents/zeroprompt/onelink/docs/contributing-guide/implementation-examples-map.mdx`
