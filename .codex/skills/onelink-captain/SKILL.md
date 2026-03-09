---
name: onelink-captain
description: "Use for Onelink Captain and AI flows: assistants, copilot, documents, scenarios, custom tools, tool registry wiring, and enterprise AI overlays."
---

# Onelink Captain

## Overview

Use this skill when the task is about Captain, copilot, knowledge documents, AI tool execution, or related enterprise AI overlays.

This skill owns the AI surface inside Onelink and should coordinate model, service, config, and enterprise prompt/tool layers together.

## Use This Skill When

- changing Captain assistants, documents, scenarios, or inbox bindings
- changing copilot threads or messages
- changing custom tool behavior or the tool registry
- editing AI-related enterprise overlays or prompt wiring
- fixing mismatches between Captain models, services, and tool configuration

## Read First

1. `/Users/akhanbakhitov/Documents/zeroprompt/onelink/AGENTS.md`
2. `/Users/akhanbakhitov/Documents/zeroprompt/onelink/docs/platform/current-architecture.mdx`
3. `/Users/akhanbakhitov/Documents/zeroprompt/onelink/docs/platform/repository-map.mdx`
4. `/Users/akhanbakhitov/Documents/zeroprompt/onelink/docs/contributing-guide/implementation-examples-map.mdx`
5. `config/agents/tools.yml`
6. the touched code paths under `app/models/`, `app/services/`, `enterprise/lib/captain/`, and `enterprise/lib/enterprise/captain/`

## Workflow

1. Identify the AI surface:
   - assistant
   - document
   - scenario
   - custom tool
   - copilot conversation flow
   - runtime config
2. Inspect current models, services, jobs, config, and enterprise overlays together.
3. Keep data contracts and tool registry behavior aligned.
4. If the task changes external tool or API behavior, coordinate with `onelink-api` or `onelink-integrations`.
5. Update docs if the operator or agent workflow changed.

## Placement Rules

- models:
  - `app/models/` with Captain and copilot namespaces
- services and jobs:
  - `app/services/`, `app/jobs/`
- AI tool registry:
  - `config/agents/tools.yml`
- enterprise overlays:
  - `enterprise/lib/captain/`, `enterprise/lib/enterprise/captain/`, and other enterprise paths that extend Captain behavior

## Captain Guardrails

- do not assume a `Captain::CustomTool` is the same as a full integration lifecycle
- do not change tool config without checking the runtime model or service path that consumes it
- do not update prompts or tool contracts in only one layer when enterprise overlays also participate
- treat AI docs as explanatory, not as proof of current runtime behavior unless code confirms them

## Verification

- targeted model, service, or request specs
- configuration consistency checks for `config/agents/tools.yml`
- narrow manual smoke check if the flow is UI- or tool-execution-heavy

## Repo Boundary Rule

Captain runtime code lives in `onelink`. Captain-related docs live in `onelink/docs`.

## References

- `/Users/akhanbakhitov/Documents/zeroprompt/onelink/docs/platform/current-architecture.mdx`
- `/Users/akhanbakhitov/Documents/zeroprompt/onelink/docs/platform/repository-map.mdx`
- `/Users/akhanbakhitov/Documents/zeroprompt/onelink/docs/contributing-guide/implementation-examples-map.mdx`
