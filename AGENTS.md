# One Link Cloud Development Guidelines

Repo paths below are relative to the One Link application repository root unless stated otherwise.

## Product Orientation

- Treat this repository as the main One Link Cloud product codebase.
- The product should be reasoned about as one shared cloud platform.
- Customer variation should be modeled through:
  - workspace access and membership
  - custom fields
  - automation
  - integrations
  - Captain configuration
- Do not model the product as separate domain-zone runtimes.
- Treat the `enterprise/` tree as a technical extension layer that participates in runtime behavior. It is not a separate customer-visible product line inside this repo.

## Build, Test, And Lint

- Setup: `bundle install && pnpm install`
- Full dev run: `pnpm dev` or `overmind start -f ./Procfile.dev`
- Light dev run: `pnpm dev:lite` or `foreman start -f ./Procfile.dev-lite`
  - starts Rails, Vite, the main Sidekiq worker, isolated MedElement workers, and WhatsApp Web history/echo workers
- Restart dev-lite: `./bin/dev-lite-restart` or `pnpm dev:lite:restart`
- Restart dev-lite and prepare DB: `PREPARE_DB=1 ./bin/dev-lite-restart`
- Enterprise bootstrap:
  - default dev-lite restart reapplies enterprise mode
  - opt out with `CW_BOOTSTRAP_ENTERPRISE=0 ./bin/dev-lite-restart`
  - manual bootstrap: `bundle exec rake chatwoot:instance:unlock_enterprise`
  - auto bootstrap during prepare: `CW_BOOTSTRAP_ENTERPRISE=1 bundle exec rake db:chatwoot_prepare`
  - optional plan label override: `CW_BOOTSTRAP_ACCOUNT_PLAN_NAME=Enterprise`
- Dev host:
  - Vite is expected on `127.0.0.1:3036`
  - open the app as `http://127.0.0.1:3000`
- Dev-lite infra:
  - `colima start --cpu 2 --memory 4 --disk 20`
  - `export DOCKER_HOST=unix://$HOME/.colima/default/docker.sock`
  - `docker compose up -d postgres redis`
  - `bundle exec rake db:chatwoot_prepare`
- Seed minimal data: `bundle exec rails db:seed`
- Seed search/perf fixtures: `bundle exec rails search:setup_test_data`
- Seed a richer account dataset:
  - `bundle exec rails runner "Internal::SeedAccountJob.perform_now(Account.find(<id>))"`
- JS lint: `pnpm eslint` or `pnpm eslint:fix`
- Ruby lint: `bundle exec rubocop -a`
- JS tests: `pnpm test` or `pnpm test:watch`
- Ruby tests: `bundle exec rspec spec/path/to/file_spec.rb`
- Single Ruby example: `bundle exec rspec spec/path/to/file_spec.rb:LINE_NUMBER`
- Always prefer `bundle exec` for Ruby CLI tasks.

## Git And Repo Boundaries

- Integration and deployment branch: `onelink-dev`.
- `onelink-main` is the upstream-sync baseline; do not deploy it directly.
- Normal product work happens directly in `onelink-dev`: verify, commit, and push. A green
  push deploys automatically to DEV; a failed gate leaves the previous DEV release running.
- Use a temporary `feature/*` or `fix/*` branch and pull request only for large, risky, or
  parallel work. Delete it after merge.
- Only a SHA that ran successfully in DEV is eligible for manual production promotion.
- The delivery pipeline and operator setup are documented in `script/onelink/README.md`.
- Do not use this fork's `develop` as the main base branch.
- Remote layout:
  - `origin` = `git@github.com:demomastra2025-eng/chatwoot.git`
  - `upstream` = `https://github.com/chatwoot/chatwoot.git`
- Push to `origin` over SSH.
- Docs repo layout:
  - `docs/` is a git submodule for `demomastra2025-eng/onelink-docs`
  - docs content commits belong in `docs/` first
  - the parent repo stores only the updated submodule pointer afterward
- Hermes skill family:
  - shared OneLink Hermes domain skills live in `/root/.hermes/shared-skills/onelink` and are loaded via `skills.external_dirs` from `/root/.hermes/shared-skills`
  - active Hermes profiles expected to see these shared skills: `default`, `tg-codex55`, `cli-spark`, `cto`
  - do not recreate repo-local `.codex/skills`; Codex skill sync was retired in favor of Hermes shared external skills
  - internal build-and-maintain skills: `onelink-builder`, `onelink-backend`, `onelink-frontend`, `onelink-api`, `onelink-integrations`, `onelink-captain`, `onelink-documentation`, `onelink-deployment`, `onelink-gitops`
  - internal Hermes operations skills include `onelink-hermes-skill-architecture`, `onelink-prod-rca`, `onelink-testing-matrix`, `onelink-notion-kanban`, `onelink-captain-runtime-deep`, and `onelink-crm-outbound-ai`
  - external API-consumer skill: `onelink-integrator`; the Claude Code bundle remains in `.claude/skills/onelink-integrator`
- Upstream sync:
  - fetch tags with `git fetch upstream --tags`
  - branch upstream synchronization work from `onelink-main`
  - use `sync/...` branches for upstream merges
  - merge the reviewed synchronization result into `onelink-dev`
  - never push product changes to `upstream`

## Architecture Read Order

Use current code first, then the docs contour that matches the task:

1. code under `app/`, `enterprise/`, `config/`, `db/`, `lib/`, and `app/javascript/`
2. `docs/internal/index.mdx`
3. `docs/internal/architecture-overview.mdx`
4. `docs/internal/repository-structure.mdx`
5. the relevant internal page under `docs/internal/`
6. `docs/AGENTS.md` and `docs/README.md` for docs-repo workflow
7. the relevant public page under `docs/platform/`, `docs/user-guide/`, `docs/integrators/`, or `docs/reference/` when user-facing behavior must stay aligned

Do not treat public product pages as proof of runtime implementation when code disagrees.

## Backend And Domain Rules

- Search both `app/` and `enterprise/` before changing shared behavior.
- Reuse native entities before inventing new abstractions:
  - `Account`
  - `AccountUser`
  - `Inbox`
  - `Contact`
  - `Company`
  - `Conversation`
  - `Message`
  - `Note`
  - `Label`
  - `AutomationRule`
  - `Macro`
  - `Integrations::App`
  - `Integrations::Hook`
  - Captain models
  - CRM entities such as pipelines, stages, deals, tasks, and field definitions
  - scheduling entities such as resources, services, appointments, payments, and expenses
- Prefer account-scoped behavior and explicit policies over global shortcuts.
- If a feature is customer-specific, prefer access, fields, configuration, and integrations before adding new shared runtime branches.
- Keep the distinction clear:
  - `Integrations::App` = integration capability
  - `Integrations::Hook` = installed integration instance
  - `Captain::CustomTool` = AI-callable tool, not a general integration lifecycle

## Frontend Rules

- The product frontend is a Rails + Vue 3 + Vite application, not a separate SPA repo.
- Main surfaces live under `app/javascript/`:
  - `dashboard/`
  - `widget/`
  - `portal/`
  - `survey/`
  - `sdk/`
  - `superadmin_pages/`
  - `shared/`
- Prefer existing `dashboard/components-next/` patterns for new reusable dashboard UI.
- Default new state to `Pinia`, but do not assume every surface already uses it.
- Prefer Tailwind utilities for new or heavily reworked UI. Do not assume the repo is already Tailwind-only.
- Avoid bare strings in Vue templates; use i18n.
- Prefer `VueUse` before adding small helper packages or bespoke low-level composables.

## Documentation Rules

- Public docs must stay client-facing and should not expose legacy upstream branding.
- Internal implementation details belong under `docs/internal/`.
- Public Mintlify navigation must expose only client-facing docs from `docs/docs.json`.
- If runtime behavior, API contracts, entity meaning, or user workflows change, update docs in the same task.
- If architecture, repo ownership, or subsystem flow changes, update internal docs in the same task.

## General Guidelines

- Keep changes minimal, coherent, and readable.
- Prefer the happy path first; add complexity only when current runtime needs it.
- Remove dead code instead of layering parallel implementations.
- Use the narrowest verification that meaningfully covers the touched surface.
- Prefer `with_modified_env` in specs over direct `ENV` stubbing.
- In reload or parallel-sensitive specs, prefer asserting `error.class.name`.
- Use non-interactive Git commands only.

## Worktree Workflow

- Prefer a separate git worktree plus branch per task when isolation helps.
- Keep Codex-specific setup under `.codex/`.
- Use `Procfile.worktree` and the local worktree environment setup, when present, for per-worktree DB and port isolation.
