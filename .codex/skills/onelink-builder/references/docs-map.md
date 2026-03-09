# Onelink Docs Map

## Use These Files First

- `/Users/akhanbakhitov/Documents/zeroprompt/onelink/AGENTS.md`
  - Repo-specific coding rules, dev commands, git flow, enterprise checklist, and translation constraints.
- `/Users/akhanbakhitov/Documents/zeroprompt/onelink/docs/platform/current-architecture.mdx`
  - Current implemented system shape.
- `/Users/akhanbakhitov/Documents/zeroprompt/onelink/docs/platform/repository-map.mdx`
  - Repo ownership, directory placement, and control files.
- `/Users/akhanbakhitov/Documents/zeroprompt/onelink/docs/contributing-guide/project-operations.mdx`
  - Runtime, delivery, API, docs, and deployment operating model.
- `/Users/akhanbakhitov/Documents/zeroprompt/onelink/docs/contributing-guide/ai-agent-operating-model.mdx`
  - Agent read order, commit boundaries, staging rules, and verification expectations.
- `/Users/akhanbakhitov/Documents/zeroprompt/onelink/docs/contributing-guide/skill-map.mdx`
  - Which specialized Onelink skill should own which task.
- `/Users/akhanbakhitov/Documents/zeroprompt/onelink/.codex/skills/`
  - Versioned project copy of the Onelink skill family.

## Development and Setup Docs

- `/Users/akhanbakhitov/Documents/zeroprompt/onelink/docs/contributing-guide/setup-guide.mdx`
  - Baseline local setup, Docker dev flow, widget test page, and test server notes.
- `/Users/akhanbakhitov/Documents/zeroprompt/onelink/docs/contributing-guide/environment-variables.mdx`
  - Development/test environment variables such as `LETTER_OPENER`.
- `/Users/akhanbakhitov/Documents/zeroprompt/onelink/docs/contributing-guide/api-documentation.mdx`
  - Swagger file layout, build command, and `/swagger` preview flow.

## Product and Channel Docs

- `/Users/akhanbakhitov/Documents/zeroprompt/onelink/docs/self-hosted/supported-features.mdx`
  - Channel matrix for supported features, message size limits, outbound restrictions, delivery status support, reply support, attachment types, and editor formatting.
- `/Users/akhanbakhitov/Documents/zeroprompt/onelink/docs/self-hosted/enterprise-edition.mdx`
  - Business context for Enterprise features such as whitelabeling, SLA, audit logs, and capacity management.

## Docs Workspace Notes

- `docs/` is its own Mintlify docs workspace and separate Git repository mounted as a submodule.
- `docs/README.md` explains local docs preview with `mint dev`.
- Use `docs/docs.json` if you need the docs navigation structure or want to place a new page consistently.
- Use `docs/contributing-guide/docs-repository-workflow.mdx` when the task changes docs content, OpenAPI docs sync, or submodule update flow.
- Use `.codex/scripts/sync-skills.sh` when a project skill changed and the installed Codex copy needs to be refreshed.

## When to Reach for Docs

- Load setup docs when local boot, Docker, or widget preview behavior matters.
- Load repository-map and project-operations first when the task is about repo ownership, cross-repo commits, or structural documentation.
- Load supported-features docs before changing channel message rules, attachment support, or reply constraints.
- Load API docs guidance when adding or renaming endpoints, request fields, or response schema.
- Load Enterprise docs when a task is driven by licensing, premium features, or self-hosted behavior rather than pure code mechanics.
