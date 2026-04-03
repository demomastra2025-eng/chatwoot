---
name: onelink-frontend
description: "Use for frontend work in Onelink: dashboard, widget, portal, survey, SDK, reusable UI, component sourcing, state management, and frontend verification."
---

# Onelink Frontend

Use this skill when the task is primarily in `app/javascript/` and needs current One Link frontend rules instead of generic Vue advice.

This skill owns frontend surface selection, component sourcing, state decisions, UI placement, and narrow verification for the existing Rails + Vue + Vite stack.

When the requirement is interaction-heavy but not visually complex, this skill prefers `VueUse` before bespoke utility code or another small helper package.

All repo paths below are relative to the One Link repository root.

## Use This Skill When

- editing dashboard routes, components, stores, API clients, or composables
- changing widget, portal, survey, SDK, or super admin frontend behavior
- adding reusable frontend components
- deciding between Pinia, legacy store patterns, local state, or existing CRUD store factories
- evaluating whether a new frontend dependency should be introduced

## Read First

1. `AGENTS.md`
2. `docs/internal/frontend-architecture.mdx`
3. `docs/internal/repository-structure.mdx`
4. `docs/internal/testing-and-tooling.mdx`
5. the relevant public page if the UI is user-facing and documented

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
   - `VueUse`
   - `reka-ui`
   - `originui-vue`
   - `shadcn-vue`
   - `Inspira UI`
4. Default new state to `Pinia`; bridge to legacy patterns only where required by the touched surface.
5. Prefer Tailwind utilities for new or heavily reworked UI.
6. If the feature changes API contracts, coordinate with `onelink-api`.

## VueUse First Rule

Before adding a helper dependency or writing a new low-level composable, check whether `VueUse` already solves the requirement cleanly.

Default `VueUse` candidates for Onelink:

- interaction and DOM behavior:
  - `useEventListener`
  - `onClickOutside`
  - `useResizeObserver`
  - `useElementSize`
  - `useWindowSize`
  - `useBreakpoints`
  - `useScroll`
  - `useIntersectionObserver`
  - `useInfiniteScroll`
- persistence and timing:
  - `useStorage`
  - `useLocalStorage`
  - `useSessionStorage`
  - `watchDebounced`
  - `useDebounceFn`
  - `useThrottleFn`
  - `useTimeoutFn`
- composable structure:
  - `createInjectionState`
  - `createSharedComposable`
  - `useToggle`
  - `useVModel`
  - `useVModels`
- form and text helpers:
  - `useTextareaAutosize`

Use `VueUse` as a utility layer, not as a replacement for the app's data architecture.

## Documentation Discipline

- If UI behavior, route structure, or dependency expectations changed, update docs in the same task.
- Update public docs for user-visible workflows.
- Update internal docs for architecture, placement, or implementation structure.
- Keep the docs commit separate in `docs/` when documentation changes are required.

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
- do not use `useFetch` or `useWebSocket` to bypass `dashboard/api/*`, existing service clients, or established transport layers
- do not use `createGlobalState` as a default store replacement when `Pinia`, a local composable, or route state is clearer
- do not add `VueUse` integrations or niche add-on packages unless the dependency already exists or the task clearly justifies it
- do not read the entire `VueUse` catalog by default; pick the specific function that matches the requirement and consult only that usage pattern

## Verification

- narrow Vitest coverage for touched logic where practical
- Histoire or local component preview for reusable UI when relevant
- manual smoke check in the touched surface using the dev server
- API coordination if the UI depends on new response fields
- if the change relies on `VueUse`-driven behavior, add a narrow test around the derived interaction or state change when practical

## Repo Boundary Rule

This skill normally edits only `onelink`. If the UI change also requires docs updates, commit docs separately in `onelink/docs`.

## References

- `docs/internal/frontend-architecture.mdx`
- `docs/internal/repository-structure.mdx`
- `docs/internal/testing-and-tooling.mdx`
