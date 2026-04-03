---
name: onelink-documentation
description: "Use for Onelink documentation work in the Mintlify docs repository: MDX pages, `docs/docs.json` navigation, docs structure, current-state clarity, and OpenAPI docs sync."
---

# Onelink Documentation

Use this skill when the task is primarily documentation work in `onelink/docs`.

This skill owns Mintlify structure, page organization, docs clarity for both clients and internal developers, and the commit flow for the separate docs repository.

All repo paths below are relative to the One Link repository root.

## Use This Skill When

- changing `onelink/docs/*.mdx`
- changing `onelink/docs/docs.json`
- restructuring navigation or adding new docs sections
- updating public product docs or hidden internal implementation docs
- syncing `onelink/docs/openapi/` after Swagger changes
- improving docs so both people and AI agents can navigate the project correctly

## Read First

1. `docs/AGENTS.md`
2. `docs/README.md`
3. `docs/docs.json`
4. `docs/introduction.mdx`
5. `docs/internal/index.mdx`
6. `docs/internal/architecture-overview.mdx`

## Workflow

1. Decide what contour you are editing:
   - public product docs
   - internal implementation docs
   - API reference
2. Validate the content against real code, repo layout, and runtime files.
3. Prefer one clear source page over multiple overlapping pages.
4. Keep public navigation in `docs/docs.json` aligned with page purpose and reading order.
5. Keep internal docs out of Mintlify navigation unless the product decision changes.
6. If API docs changed, sync `openapi/` from the app repo.
7. If the task changes project skills, update the versioned copy in `.codex/skills` and then sync the installed copy into `$CODEX_HOME/skills`.
8. Commit the docs content in `onelink/docs` first.
9. If needed, update the `docs` submodule pointer in the parent `onelink` repo.

## Documentation Discipline

- Always start from current code before rewriting structure or claims.
- Documentation work is required whenever behavior, architecture meaning, API contracts, operator flow, or skill workflow changed.
- Prefer updating the existing source page over creating overlapping pages.

## Documentation Rules

- public pages must stay client-facing and product-focused
- internal pages may describe repo paths, DB, architecture, integrations, and runtime logic
- public docs should describe One Link as one shared cloud core, not as separate domain runtimes
- do not surface legacy upstream branding in public docs
- do not duplicate the same workflow in multiple pages unless one page is a short index that points to the source page

## Mintlify Rules

- update `docs/docs.json` when adding, moving, renaming, or removing public pages
- keep pages grouped by purpose, not by chronology
- prefer stable page identifiers that match the content
- validate that every navigation target exists as `.mdx` or `.md`

## Verification

- parse `docs/docs.json`
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
- `docs/internal/index.mdx`
- `docs/internal/architecture-overview.mdx`
- `docs/docs.json`
