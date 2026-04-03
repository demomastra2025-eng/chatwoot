# Onelink Docs Map

## Use These Files First

- `AGENTS.md`
  - Repo-specific coding rules, dev commands, git flow, architecture read order, and skill sync rules.
- `docs/AGENTS.md`
  - Docs-repo specific editing rules and contour boundaries.
- `docs/README.md`
  - Docs contour overview and local preview workflow.
- `docs/internal/index.mdx`
  - Entry point for hidden internal documentation.
- `docs/internal/architecture-overview.mdx`
  - Current implemented system shape.
- `docs/internal/repository-structure.mdx`
  - Repo ownership, directory placement, and control files.
- `.codex/skills/`
  - Versioned project copy of the Onelink skill family.
- `.codex/scripts/sync-skills.sh`
  - Syncs the versioned project skill family into the installed Codex runtime copy.

## Public Product Docs

- `docs/introduction.mdx`
  - Public product entry point.
- `docs/getting-started/quick-start.mdx`
  - Fast client onboarding.
- `docs/getting-started/workspace-setup.mdx`
  - Workspace, members, and initial setup.
- `docs/platform/overview.mdx`
  - Public product architecture summary.
- `docs/platform/entity-matrix.mdx`
  - Core entities and how they relate.

## Public Task-Specific Docs

- `docs/platform/communication-workflows.mdx`
  - Communication and inbox behavior.
- `docs/platform/crm-architecture.mdx`
  - CRM model and flexible data.
- `docs/platform/scheduling-and-payments.mdx`
  - Scheduling, appointments, payments, and related flows.
- `docs/platform/captain-ai.mdx`
  - Captain behavior and concepts.
- `docs/platform/integrations-architecture.mdx`
  - Automations and integrations.
- `docs/user-guide/`
  - End-user workflow pages.
- `docs/integrators/`
  - External integration and API-consumer pages.
- `docs/reference/`
  - FAQ and glossary.

## Docs Workspace Notes

- `docs/` is its own Mintlify docs workspace and separate Git repository mounted as a submodule.
- `docs/README.md` explains local docs preview with `mint dev`.
- Use `docs/docs.json` if you need the docs navigation structure or want to place a new page consistently.
- Keep internal docs out of `docs/docs.json`.
- Use `.codex/scripts/sync-skills.sh` when a project skill changed and the installed Codex copy needs to be refreshed.

## When to Reach for Docs

- Load internal docs first when the task is about architecture, repo ownership, runtime internals, data modeling, or engineering workflow.
- Load public docs when the task changes what clients, operators, or integrators should understand about the product.
- Load integrator docs before changing external API usage guidance, webhook behavior, or integration setup language.
- Load API docs guidance when adding or renaming endpoints, request fields, or response schema.
