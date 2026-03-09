---
name: onelink-frontend
description: "Use for frontend work in Onelink: dashboard, widget, portal, survey, SDK, reusable UI, component sourcing, state management, and frontend verification."
---

# Onelink Frontend

## Overview

Use this skill when the task is primarily in `app/javascript/` and needs current Onelink frontend rules instead of generic Vue advice.

This skill owns frontend surface selection, component sourcing, state decisions, UI placement, and narrow verification for the existing Rails + Vue + Vite stack.

## Use This Skill When

- editing dashboard routes, components, stores, API clients, or composables
- changing widget, portal, survey, SDK, or super admin frontend behavior
- adding reusable frontend components
- deciding between Pinia, legacy store patterns, local state, or existing CRUD store factories
- evaluating whether a new frontend dependency should be introduced

## Read First

1. `/Users/akhanbakhitov/Documents/zeroprompt/onelink/AGENTS.md`
2. `/Users/akhanbakhitov/Documents/zeroprompt/onelink/docs/platform/current-architecture.mdx`
3. `/Users/akhanbakhitov/Documents/zeroprompt/onelink/docs/platform/frontend-implementation.mdx`
4. `/Users/akhanbakhitov/Documents/zeroprompt/onelink/docs/contributing-guide/frontend-agent-playbook.mdx`
5. `/Users/akhanbakhitov/Documents/zeroprompt/onelink/docs/contributing-guide/frontend-dependency-policy.mdx`
6. `/Users/akhanbakhitov/Documents/zeroprompt/onelink/docs/contributing-guide/dashboard-feature-template.mdx`
7. `/Users/akhanbakhitov/Documents/zeroprompt/onelink/docs/contributing-guide/design-tokens-and-ui-conventions.mdx`
8. `/Users/akhanbakhitov/Documents/zeroprompt/onelink/docs/contributing-guide/implementation-examples-map.mdx`
9. `/Users/akhanbakhitov/Documents/zeroprompt/onelink/docs/contributing-guide/testing-strategy-for-agents.mdx`

## Workflow

1. Identify the owning frontend surface:
   - `dashboard`
   - `widget`
   - `portal`
   - `survey`
   - `sdk`
   - `shared`
   - `superadmin_pages`
2. Search for an existing route, component, or store before creating a new pattern.
3. Source components in this order:
   - existing `components-next`
   - similar local route screens
   - `reka-ui`
   - `shadcn-vue`
   - `PrimeVue` only for dense admin patterns when wrappers are insufficient
4. Default new state to `Pinia`; bridge to legacy patterns only where required by the touched surface.
5. Prefer Tailwind utilities for new or heavily reworked UI.
6. If the feature changes API contracts, coordinate with `onelink-api`.

## Placement Rules

- dashboard UI:
  - `app/javascript/dashboard/`
- reusable message and modern dashboard UI:
  - `app/javascript/dashboard/components-next/`
- embedded widget:
  - `app/javascript/widget/`
- help center frontend:
  - `app/javascript/portal/`
- survey surfaces:
  - `app/javascript/survey/`
- SDK frontend assets:
  - `app/javascript/sdk/`
- shared helpers and composables:
  - `app/javascript/shared/`

## Frontend Guardrails

- do not assume the repo is fully Tailwind-only
- do not assume every surface already uses Pinia
- do not expose third-party component APIs directly if a local wrapper is more stable
- do not add bare strings in templates
- do not introduce a new design language when an existing local pattern already fits

## Verification

- narrow Vitest coverage for touched logic where practical
- Histoire or local component preview for reusable UI when relevant
- manual smoke check in the touched surface using the dev server
- API coordination if the UI depends on new response fields

## Repo Boundary Rule

This skill normally edits only `onelink`. If the UI change also requires docs updates, commit docs separately in `onelink/docs`.

## References

- `/Users/akhanbakhitov/Documents/zeroprompt/onelink/docs/platform/frontend-implementation.mdx`
- `/Users/akhanbakhitov/Documents/zeroprompt/onelink/docs/contributing-guide/frontend-agent-playbook.mdx`
- `/Users/akhanbakhitov/Documents/zeroprompt/onelink/docs/contributing-guide/frontend-dependency-policy.mdx`
- `/Users/akhanbakhitov/Documents/zeroprompt/onelink/docs/contributing-guide/dashboard-feature-template.mdx`
- `/Users/akhanbakhitov/Documents/zeroprompt/onelink/docs/contributing-guide/design-tokens-and-ui-conventions.mdx`
- `/Users/akhanbakhitov/Documents/zeroprompt/onelink/docs/contributing-guide/implementation-examples-map.mdx`
- `/Users/akhanbakhitov/Documents/zeroprompt/onelink/docs/contributing-guide/testing-strategy-for-agents.mdx`
