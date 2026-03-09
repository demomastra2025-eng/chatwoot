---
name: onelink-documentation
description: "Use for Onelink documentation work in the Mintlify docs repository: MDX pages, docs.json navigation, docs structure, current-state vs roadmap clarity, and OpenAPI docs sync."
---

# Onelink Documentation

## Overview

Use this skill when the task is primarily documentation work in `onelink/docs`.

This skill owns Mintlify structure, page organization, docs clarity for human analysts and AI agents, and the commit flow for the separate docs repository.

All repo paths below are relative to the Onelink repository root.

## Use This Skill When

- changing `onelink/docs/*.mdx`
- changing `onelink/docs/docs.json`
- restructuring navigation or adding new docs sections
- updating architecture, workflow, API, or deployment documentation
- syncing `onelink/docs/openapi/` after Swagger changes
- improving docs so both people and AI agents can navigate the project correctly

## Read First

1. `docs/AGENTS.md`
2. `docs/README.md`
3. `docs/platform/current-architecture.mdx`
4. `docs/platform/repository-map.mdx`
5. `docs/contributing-guide/project-operations.mdx`
6. `docs/contributing-guide/ai-agent-operating-model.mdx`
7. `docs/contributing-guide/skill-map.mdx`
8. `docs/contributing-guide/docs-repository-workflow.mdx`

## Workflow

1. Decide what kind of doc you are editing:
   - current state
   - target direction
   - implementation playbook
   - operator guide
   - API reference
2. Validate the content against real code, repo layout, and runtime files.
3. Prefer one clear source page over multiple overlapping pages.
4. Keep navigation in `docs.json` aligned with page purpose and reading order.
5. If API docs changed, sync `openapi/` from the app repo.
6. If the task changes project skills, update the versioned copy in `.codex/skills` and then sync the installed copy into `$CODEX_HOME/skills`.
7. Commit the docs content in `onelink/docs` first.
8. If needed, update the `docs` submodule pointer in the parent `onelink` repo.

## Documentation Discipline

- Always start from current code and current-state docs before rewriting structure or claims.
- Documentation work is required whenever behavior, architecture meaning, API contracts, operator flow, or skill workflow changed.
- Prefer updating the existing source page over creating overlapping pages.

## Documentation Rules

- current-state pages must describe what exists today
- roadmap pages must clearly read as intent, not implementation
- repo and path names should be explicit when a page guides analysts or agents
- structural docs should explain which repo owns which change
- do not duplicate the same workflow in multiple pages unless one page is a short index that points to the source page

## Mintlify Rules

- update `docs.json` when adding, moving, renaming, or removing pages
- keep pages grouped by purpose, not by random chronology
- prefer stable page identifiers that match the content
- validate that every navigation target exists as `.mdx` or `.md`

## Verification

- parse `docs.json`
- validate navigation targets
- verify linked structural pages exist
- run `./scripts/sync-openapi-from-onelink.sh` when API reference files should change
- use `mint dev` when local preview is needed

## Repo Boundary Rule

This skill edits the separate docs repository mounted at `onelink/docs`. Product code changes still belong to the parent `onelink` repo.
Versioned skill sources belong in `.codex/skills`. Installed Codex runtime skills belong in `$CODEX_HOME/skills`.

## References

- `docs/AGENTS.md`
- `docs/README.md`
- `docs/platform/repository-map.mdx`
- `docs/contributing-guide/project-operations.mdx`
- `docs/contributing-guide/ai-agent-operating-model.mdx`
- `docs/contributing-guide/skill-map.mdx`
- `docs/contributing-guide/docs-repository-workflow.mdx`
