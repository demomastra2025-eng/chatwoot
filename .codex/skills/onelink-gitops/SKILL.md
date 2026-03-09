---
name: onelink-gitops
description: "Use for Git, GitHub, submodule, branch, release, and upstream-sync work in Onelink, including syncing changes from Chatwoot into the fork."
---

# Onelink GitOps

## Overview

Use this skill when the task is mainly about repository operations rather than product runtime behavior.

This skill owns GitHub flow, branch discipline, submodule updates, versioned skill sync, and the upstream sync process from Chatwoot.

All repo paths below are relative to the Onelink repository root.

## Use This Skill When

- creating or cleaning feature, fix, chore, or sync branches
- preparing or validating GitHub push and PR flow
- updating the `docs/` submodule pointer
- syncing the versioned project skills into `$CODEX_HOME/skills`
- fetching and merging upstream Chatwoot changes
- validating remote layout or branch strategy

## Read First

1. `AGENTS.md`
2. `docs/contributing-guide/project-operations.mdx`
3. `docs/contributing-guide/ai-agent-operating-model.mdx`
4. `docs/contributing-guide/docs-repository-workflow.mdx`
5. `docs/development/upstream-sync.mdx`
6. `docs/contributing-guide/skill-map.mdx`

## Workflow

1. Classify the repo operation:
   - normal product branch flow
   - docs submodule update
   - skill sync
   - upstream sync from Chatwoot
2. Confirm the correct repo boundary:
   - product code and versioned skills commit in `onelink`
   - docs content commit in `docs/`
3. Use non-interactive Git commands only.
4. Keep path-limited commits when unrelated staged or unstaged work already exists.
5. Push to `origin` over SSH.
6. Never push product changes to `upstream`.

## Documentation Discipline

- Read the Git and workflow docs before editing branches or remotes.
- If branch model, submodule flow, or sync process changed, update `docs/` in the same task.
- Keep docs commits separate in `docs/` when the change belongs to the docs repository.

## Branch Rules

- base product branch: `onelink-main`
- normal delivery branches: `feature/...`, `fix/...`, `chore/...`
- upstream sync branches: `sync/chatwoot-vX.Y.Z`
- do not use this fork's `develop` as the main working branch

## Upstream Sync Rules

- fetch upstream tags first
- create a dedicated `sync/...` branch from `onelink-main`
- merge the chosen upstream release there
- resolve conflicts and verify before merging back
- keep intentional divergences documented

## Submodule And Skill Sync Rules

- docs content changes commit in `docs/` first, then update the parent repo pointer in `onelink`
- versioned skill changes commit in `.codex/skills`
- sync installed runtime skills with `./.codex/scripts/sync-skills.sh to-codex-home`

## Verification

- `git status`
- `git remote -v`
- `git branch --show-current`
- `git submodule status` when docs pointer matters
- narrow diff inspection before commit and push

## References

- `AGENTS.md`
- `docs/contributing-guide/project-operations.mdx`
- `docs/contributing-guide/ai-agent-operating-model.mdx`
- `docs/contributing-guide/docs-repository-workflow.mdx`
- `docs/development/upstream-sync.mdx`
