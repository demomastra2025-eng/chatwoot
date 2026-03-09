# Chatwoot Development Guidelines

## Build / Test / Lint

- **Setup**: `bundle install && pnpm install`
- **Run Dev**: `pnpm dev` or `overmind start -f ./Procfile.dev`
- **Run Dev Lite**: `foreman start -f ./Procfile.dev-lite` for low-resource development with hot reload and without Sidekiq
- **Restart Dev Lite**: `./bin/dev-lite-restart` or `pnpm dev:lite:restart`
- **Restart Dev Lite + DB Prepare**: `PREPARE_DB=1 ./bin/dev-lite-restart` when migrations or database setup changed
- **Enterprise bootstrap**:
  - Dev lite restart now reapplies enterprise mode by default; opt out with `CW_BOOTSTRAP_ENTERPRISE=0 ./bin/dev-lite-restart`
  - Manual bootstrap in any non-test env: `bundle exec rake chatwoot:instance:unlock_enterprise`
  - Automatic bootstrap during `db:chatwoot_prepare`: set `CW_BOOTSTRAP_ENTERPRISE=1`
  - Optional account plan label override: `CW_BOOTSTRAP_ACCOUNT_PLAN_NAME=Enterprise`
- **Dev Host**: local Vite is expected on `127.0.0.1:3036`; open the app as `http://127.0.0.1:3000` to avoid host mismatches with HMR
- **Infra for Dev Lite**:
  - Start Colima if Docker Desktop is not running: `colima start --cpu 2 --memory 4 --disk 20`
  - Point Docker CLI to Colima: `export DOCKER_HOST=unix:///Users/akhanbakhitov/.colima/default/docker.sock`
  - Start only database services: `docker compose up -d postgres redis`
  - On first boot or after DB reset: `bundle exec rake db:chatwoot_prepare`
- **Seed Local Test Data**: `bundle exec rails db:seed` (quickly populates minimal data for standard feature verification)
- **Seed Search Test Data**: `bundle exec rails search:setup_test_data` (bulk fixture generation for search/performance/manual load scenarios)
- **Seed Account Sample Data (richer test data)**: `Seeders::AccountSeeder` is available as an internal utility and is exposed through Super Admin `Accounts#seed`, but can be used directly in dev workflows too:
  - UI path: Super Admin → Accounts → Seed (enqueues `Internal::SeedAccountJob`).
  - CLI path: `bundle exec rails runner "Internal::SeedAccountJob.perform_now(Account.find(<id>))"` (or call `Seeders::AccountSeeder.new(account: Account.find(<id>)).perform!` directly).
- **Lint JS/Vue**: `pnpm eslint` / `pnpm eslint:fix`
- **Lint Ruby**: `bundle exec rubocop -a`
- **Test JS**: `pnpm test` or `pnpm test:watch`
- **Test Ruby**: `bundle exec rspec spec/path/to/file_spec.rb`
- **Single Test**: `bundle exec rspec spec/path/to/file_spec.rb:LINE_NUMBER`
- **Run Project**: `overmind start -f Procfile.dev`
- **Ruby Version**: Manage Ruby via `rbenv` and install the version listed in `.ruby-version` (e.g., `rbenv install $(cat .ruby-version)`)
- **rbenv setup**: Before running any `bundle` or `rspec` commands, init rbenv in your shell (`eval "$(rbenv init -)"`) so the correct Ruby/Bundler versions are used
- Always prefer `bundle exec` for Ruby CLI tasks (rspec, rake, rubocop, etc.)

## Git / GitHub Workflow

- **Primary branch**: `onelink-main`
- **Do not use as base branch**: `develop` in this fork is not the product base branch
- **Remote layout**:
  - `origin` = `git@github.com:demomastra2025-eng/chatwoot.git`
  - `upstream` = `https://github.com/chatwoot/chatwoot.git`
- **Docs repo layout**:
  - `docs/` is a git submodule that points to `git@github.com:demomastra2025-eng/onelink-docs.git`
  - treat `/Users/akhanbakhitov/Documents/zeroprompt/onelink/docs` as readable local files plus a separate Git repository
  - docs content commits belong in the `docs/` repository first
  - the parent `onelink` repository stores only the submodule pointer update after a docs commit
- **Before docs work**:
  - run `git submodule update --init --recursive` after cloning or when `docs/` is missing
  - if docs were edited in Mintlify or elsewhere, pull the latest changes inside `docs/` before using them as the source of truth
- **Local skill family**:
  - versioned project skill source lives under `/Users/akhanbakhitov/Documents/zeroprompt/onelink/.codex/skills`
  - installed Codex runtime copy lives under `/Users/akhanbakhitov/.codex/skills`
  - use `onelink-builder` for broad or cross-surface work
  - use the specialized skills for narrow work: `onelink-backend`, `onelink-frontend`, `onelink-api`, `onelink-integrations`, `onelink-captain`, `onelink-documentation`, `onelink-deployment`
  - after changing the versioned project copy, sync it to Codex home with `./.codex/scripts/sync-skills.sh to-codex-home`
- **Pushes must use SSH**:
  - Verify with `git remote -v`
  - Push with `git push origin HEAD`
  - For a new branch use `git push -u origin <branch-name>`
- **SSH auth check**: `ssh -T git@github.com`
- **Daily branch flow**:
  - Branch from `onelink-main`
  - Prefer branch names like `feature/...`, `fix/...`, `chore/...`, `sync/...`
  - Commit locally, then push to `origin` over SSH
  - When a deliverable has a reusable base plus an optional feature, use stacked branches:
    - commit the shared/base work in one branch first
    - branch the optional feature from that base branch
    - push both branches so the base can merge independently from the optional feature
- **Syncing with upstream Chatwoot**:
  - Prefer stable upstream tags over `upstream/develop` for product updates
  - Fetch updates with `git fetch upstream --tags`
  - Create a sync branch from `onelink-main`, for example `sync/chatwoot-v4.11.1`
  - Merge the target upstream tag or branch into that sync branch
  - Resolve conflicts there, verify app boot/tests, then merge back into `onelink-main`
- **Avoid**:
  - Pushing to `upstream`
  - Using HTTPS for `origin` pushes
  - Force-pushing `onelink-main` unless explicitly requested
  - Using `develop` from this fork as the main working branch

## Code Style

- **Ruby**: Follow RuboCop rules (150 character max line length)
- **Vue/JS**: Use ESLint (Airbnb base + Vue 3 recommended)
- **Vue Components**: Use PascalCase
- **Events**: Use camelCase
- **I18n**: No bare strings in templates; use i18n
- **Error Handling**: Use custom exceptions (`lib/custom_exceptions/`)
- **Models**: Validate presence/uniqueness, add proper indexes
- **Type Safety**: Use PropTypes in Vue, strong params in Rails
- **Naming**: Use clear, descriptive names with consistent casing
- **Vue API**: For new or heavily reworked components, prefer Composition API with `<script setup>`. Do not assume the existing repo already follows this everywhere.

## Styling

- **Tailwind Preferred For New Work**:
  - For new or heavily reworked surfaces, prefer Tailwind utility classes
  - Do not assume the existing repo is already Tailwind-only
  - Existing SCSS and scoped styles still exist in multiple frontend surfaces
  - Avoid introducing new styling patterns unless the touched surface already depends on them
- **Colors**: Refer to `tailwind.config.js` for color definitions

## Frontend Implementation

- Keep the existing `Rails + Vue 3 + Vite` shell for dashboard work; do not introduce `Nuxt` as a parallel runtime for product features.
- For new reusable dashboard UI, prefer `app/javascript/dashboard/components-next/`.
- Default new feature state to `Pinia`; bridge to existing `Vuex` only where necessary. Reuse `dashboard/store/storeFactory.js` when the existing CRUD pattern fits.
- For forms, prefer `components-next` inputs/dialogs/selects with `Vuelidate`. Use `FormKit` only when schema-driven forms clearly benefit from it.
- Use `Histoire` for reusable components and visually complex feature surfaces.
- For frontend execution workflow, follow `/Users/akhanbakhitov/Documents/zeroprompt/onelink/docs/contributing-guide/frontend-agent-playbook.mdx`.
- For frontend package decisions, follow `/Users/akhanbakhitov/Documents/zeroprompt/onelink/docs/contributing-guide/frontend-dependency-policy.mdx`.
- For new dashboard module structure, follow `/Users/akhanbakhitov/Documents/zeroprompt/onelink/docs/contributing-guide/dashboard-feature-template.mdx`.
- For visual consistency, follow `/Users/akhanbakhitov/Documents/zeroprompt/onelink/docs/contributing-guide/design-tokens-and-ui-conventions.mdx`.
- For concrete code references, follow `/Users/akhanbakhitov/Documents/zeroprompt/onelink/docs/contributing-guide/implementation-examples-map.mdx`.
- For verification depth, follow `/Users/akhanbakhitov/Documents/zeroprompt/onelink/docs/contributing-guide/testing-strategy-for-agents.mdx`.
- For docs-specific workflow, read `/Users/akhanbakhitov/Documents/zeroprompt/onelink/docs/AGENTS.md` and `/Users/akhanbakhitov/Documents/zeroprompt/onelink/docs/contributing-guide/docs-repository-workflow.mdx`.
- Source new component ideas in this order:
  1. existing `components-next` components and stories
  2. similar route screens already present in `onelink`
  3. `reka-ui` for accessible headless primitives
  4. `shadcn-vue` for recipes and implementation patterns
  5. `PrimeVue` for dense admin/table/filter patterns only when local wrappers are insufficient
  6. `Inspira UI` for visual inspiration only
- Wrap third-party primitives in local components instead of letting external libraries become the public UI API of the app.
- For a current native module reference, use `app/javascript/dashboard/routes/dashboard/scheduling/`, `app/javascript/dashboard/components-next/Scheduling/`, `app/javascript/dashboard/stores/scheduling/`, and `app/services/scheduling/`.

## Architecture Sources

Use architecture materials in this order:

1. code in `app/`, `enterprise/`, `config/`, and `db/`
2. `/Users/akhanbakhitov/Documents/zeroprompt/onelink/docs/platform/current-architecture.mdx` for the current implemented system
3. `/Users/akhanbakhitov/Documents/zeroprompt/onelink/docs/platform/repository-map.mdx` when the task depends on knowing which repo, directory, or control file owns the change
4. `/Users/akhanbakhitov/Documents/zeroprompt/onelink/docs/contributing-guide/project-operations.mdx` when the task spans runtime, docs, API contracts, or delivery flow
5. `/Users/akhanbakhitov/Documents/zeroprompt/onelink/docs/contributing-guide/ai-agent-operating-model.mdx` when the task spans app code, docs, or local skills and needs clean commit boundaries
6. `/Users/akhanbakhitov/Documents/zeroprompt/onelink/docs/contributing-guide/skill-map.mdx` when the agent needs to choose the correct project skill
7. `/Users/akhanbakhitov/Documents/zeroprompt/onelink/docs/contributing-guide/backend-agent-playbook.mdx` when the task is a backend implementation task and the agent needs placement and execution rules
8. `/Users/akhanbakhitov/Documents/zeroprompt/onelink/docs/platform/frontend-implementation.mdx` when the task touches frontend structure, component sourcing, state management, or library choices
9. `/Users/akhanbakhitov/Documents/zeroprompt/onelink/docs/contributing-guide/frontend-agent-playbook.mdx` when the task is a frontend implementation task and the agent needs placement, reuse, extension, or verification rules
10. `/Users/akhanbakhitov/Documents/zeroprompt/onelink/docs/contributing-guide/frontend-dependency-policy.mdx` when the task may require a new frontend dependency
11. `/Users/akhanbakhitov/Documents/zeroprompt/onelink/docs/contributing-guide/dashboard-feature-template.mdx` when the task creates a new dashboard feature or module
12. `/Users/akhanbakhitov/Documents/zeroprompt/onelink/docs/contributing-guide/backend-feature-template.mdx` when the task creates a new backend feature shape
13. `/Users/akhanbakhitov/Documents/zeroprompt/onelink/docs/contributing-guide/design-tokens-and-ui-conventions.mdx` when the task needs practical UI styling conventions
14. `/Users/akhanbakhitov/Documents/zeroprompt/onelink/docs/contributing-guide/implementation-examples-map.mdx` when the task needs concrete code references
15. `/Users/akhanbakhitov/Documents/zeroprompt/onelink/docs/contributing-guide/testing-strategy-for-agents.mdx` when the task needs verification guidance
16. `/Users/akhanbakhitov/Documents/zeroprompt/onelink/docs/contributing-guide/domain-access-architecture.md` for current account/access/entity rules and extension strategy
17. `/Users/akhanbakhitov/Documents/zeroprompt/onelink/docs/platform/implementation-roadmap.mdx` for delivery order, phases, and rollout strategy
18. `/Users/akhanbakhitov/Documents/zeroprompt/onelink/docs/platform/overview.mdx`, `/Users/akhanbakhitov/Documents/zeroprompt/onelink/docs/platform/crm-architecture.mdx`, and `/Users/akhanbakhitov/Documents/zeroprompt/onelink/docs/domains/overview.mdx` for target direction and planning constraints
19. `/Users/akhanbakhitov/Documents/zeroprompt/onelink/docs/contributing-guide/docs-repository-workflow.mdx` when the task changes docs content, docs publishing, Mintlify setup, or OpenAPI docs sync

Do not treat target architecture documents as proof that the runtime implementation already exists.
Use the implementation roadmap when the task is about sequencing, decomposition, or deciding what to build next.

## General Guidelines

- MVP focus: Least code change, happy-path only
- No unnecessary defensive programming
- Ship the happy path first: limit guards/fallbacks to what production has proven necessary, then iterate
- Prefer minimal, readable code over elaborate abstractions; clarity beats cleverness
- Break down complex tasks into small, testable units
- Iterate after confirmation
- Avoid writing specs unless explicitly asked
- Remove dead/unreachable/unused code
- Don’t write multiple versions or backups for the same logic — pick the best approach and implement it
- Prefer `with_modified_env` (from spec helpers) over stubbing `ENV` directly in specs
- Specs in parallel/reloading environments: prefer comparing `error.class.name` over constant class equality when asserting raised errors

## Product Architecture Direction

- Treat `/Users/akhanbakhitov/Documents/zeroprompt/onelink` as the primary product fork, not as a temporary patch layer.
- Current implemented shape first: this repo is today an account-scoped omnichannel support platform with CRM-adjacent primitives and an inherited `enterprise/` technical split. In Onelink, that split is not a separate product/paywall boundary because enterprise capabilities are currently opened for the project.
- Keep three conceptual layers in mind:
  - `upstream/core`: Chatwoot-compatible base and smallest possible fork diff
  - `platform`: shared Onelink capabilities, branding, shared CRM behavior, shared integrations, shared access model
  - `domain zones`: isolated vertical behavior such as healthcare and construction
- Do not model verticals by scattering conditionals across shared core code when an isolated extension point or domain service will work.
- If a feature is needed by 2 or more domain zones, prefer promoting it into the shared platform layer.
- If a feature is needed by only 1 tenant, prefer configuration/custom attributes/forms before adding new shared code.
- Keep domain specialization separate from plan/licensing logic. A domain is not the same thing as the inherited `enterprise/` tree or any future capability gating.

## CRM Architecture Direction

- Build one shared CRM engine, not separate CRMs per vertical.
- Current implemented CRM-adjacent primitives are `Contact`, `Company`, `Note`, `Label`, `CustomAttributeDefinition`, search/reporting, and communication history around `Conversation`.
- Planned shared CRM entities such as `Deal`, `Task`, `Pipeline`, `Stage`, and `Activity` should be treated as roadmap until they exist in code.
- Shared CRM entities should remain explicit business entities. In particular, `Deal` and `Task` should be separate entities, not one generic record with overloaded state.
- Treat `Company` as an existing shared CRM organization entity in this repo. It should be reused as the default B2B grouping layer across generic, healthcare, and construction flows instead of inventing parallel organization models too early.
- Keep `Contact` as the person-level entity and `Company` as the organization-level entity. Prefer attaching future organization-centric CRM flows such as deals/projects/cases to `company_id` when appropriate.
- Use custom attributes to extend CRM entities, not to replace core state and relationships.
- Use `Company` custom attributes for domain-specific organization data before adding separate vertical-specific company tables.
- Reuse the existing native platform primitives before inventing new ones:
  - `Account` as workspace/tenant boundary
  - `Contact` as person-level entity
  - `Company` as organization-level entity
  - `Conversation` as communication layer
  - `Note` as internal contact note layer
  - `Label` as lightweight segmentation
  - `CustomAttributeDefinition` as current schema layer for contact/conversation variance
  - `Team` as shared ownership/routing primitive
  - `Macro`, `AutomationRule`, `Integrations::App`, and `Integrations::Hook` as native operational and integration primitives
  - `Captain` as shared AI/knowledge/tooling layer
- Keep the distinction clear:
  - `Integrations::App` = integration catalog/capability descriptor
  - `Integrations::Hook` = installed account/inbox integration instance
  - `Captain::CustomTool` = AI-callable tool, not a full integration lifecycle by default
- Treat notes, labels, custom attributes, teams, macros, automations, integrations, and Captain as first-class extension points when designing domain behavior.
- Put stable shared behavior such as pipelines, stages, ownership, activities, permissions, and base UI in shared platform code.
- Put domain-specific fields, screens, workflows, reports, and validations in domain-scoped code.
- Treat `generic` as a first-class domain profile for broad/non-vertical customers.

## Domain Change Rules

- Before implementing a new domain feature, decide whether it belongs to:
  - shared platform capability
  - domain-specific behavior
  - tenant-specific configuration
- Do not assume `generic`, `healthcare`, and `construction` already exist as runtime-bounded contexts. Verify concrete implementation points first.
- Avoid adding healthcare/construction-specific columns into shared tables unless the field is truly stable and shared.
- Prefer this escalation path:
  - existing native entity + config/labels/notes/custom attributes/Captain
  - domain service/policy/UI extension
  - new domain model
- Before adding a new entity, explicitly check whether `Account`, `Company`, `Contact`, `Conversation`, `Note`, `Label`, `Team`, `Macro`, `AutomationRule`, `Integrations::App`, `Integrations::Hook`, or `Captain` already cover the need.
- When changing shared code, verify that the behavior still makes sense for:
  - generic accounts
  - healthcare accounts
  - construction accounts
- Use code plus `/Users/akhanbakhitov/Documents/zeroprompt/onelink/docs/platform/current-architecture.mdx` as the current-state source of truth, and use `/Users/akhanbakhitov/Documents/zeroprompt/onelink/docs/contributing-guide/domain-access-architecture.md` as the companion guide for access/entity decisions.
- Use `/Users/akhanbakhitov/Documents/zeroprompt/onelink/docs/platform/implementation-roadmap.mdx` when the task is roadmap-driven or requires phase-aware implementation planning.

## Codex Worktree Workflow

- Use a separate git worktree + branch per task to keep changes isolated.
- Keep Codex-specific local setup under `.codex/` and use `Procfile.worktree` for worktree process orchestration.
- The setup workflow in `.codex/environments/environment.toml` should dynamically generate per-worktree DB/port values (Rails, Vite, Redis DB index) to avoid collisions.
- Start each worktree with its own Overmind socket/title so multiple instances can run at the same time.
- If using a worktree for this repo, preserve the same git remote layout: `origin` over SSH and `upstream` pointing to `chatwoot/chatwoot`

## Commit Messages

- Prefer Conventional Commits: `type(scope): subject` (scope optional)
- Example: `feat(auth): add user authentication`
- Don't reference Claude in commit messages

## Project-Specific

- **Translations**:
  - Only update `en.yml` and `en.json`
  - Other languages are handled by the community
  - Backend i18n → `en.yml`, Frontend i18n → `en.json`
- **Frontend**:
  - Use `components-next/` for message bubbles
  - Prefer `components-next/` for new reusable dashboard components
  - Follow `/Users/akhanbakhitov/Documents/zeroprompt/onelink/docs/platform/frontend-implementation.mdx` for frontend structure and component sourcing policy
  - Follow `/Users/akhanbakhitov/Documents/zeroprompt/onelink/docs/contributing-guide/frontend-agent-playbook.mdx` for the concrete agent workflow: reuse vs extend vs create, file placement, and verification
  - Follow `/Users/akhanbakhitov/Documents/zeroprompt/onelink/docs/contributing-guide/frontend-dependency-policy.mdx` for new package decisions
  - Follow `/Users/akhanbakhitov/Documents/zeroprompt/onelink/docs/contributing-guide/dashboard-feature-template.mdx` for default module structure
  - Follow `/Users/akhanbakhitov/Documents/zeroprompt/onelink/docs/contributing-guide/design-tokens-and-ui-conventions.mdx` for practical UI conventions
  - Follow `/Users/akhanbakhitov/Documents/zeroprompt/onelink/docs/contributing-guide/implementation-examples-map.mdx` for canonical code references
  - Follow `/Users/akhanbakhitov/Documents/zeroprompt/onelink/docs/contributing-guide/testing-strategy-for-agents.mdx` for verification depth
- **Backend**:
  - Follow `/Users/akhanbakhitov/Documents/zeroprompt/onelink/docs/contributing-guide/backend-agent-playbook.mdx` for backend execution workflow: native entity reuse, placement, and `enterprise/` checks
  - Follow `/Users/akhanbakhitov/Documents/zeroprompt/onelink/docs/contributing-guide/backend-feature-template.mdx` for default backend feature structure
  - Follow `/Users/akhanbakhitov/Documents/zeroprompt/onelink/docs/contributing-guide/implementation-examples-map.mdx` for canonical code references
  - Follow `/Users/akhanbakhitov/Documents/zeroprompt/onelink/docs/contributing-guide/testing-strategy-for-agents.mdx` for verification depth
- **Docs**:
  - Edit docs content inside `/Users/akhanbakhitov/Documents/zeroprompt/onelink/docs`, but remember it is a separate Git repository
  - Commit docs content inside `docs/` first, then commit the updated `docs` submodule pointer in the parent `onelink` repo when needed
  - Follow `/Users/akhanbakhitov/Documents/zeroprompt/onelink/docs/AGENTS.md` and `/Users/akhanbakhitov/Documents/zeroprompt/onelink/docs/contributing-guide/docs-repository-workflow.mdx`

## Ruby Best Practices

- Use compact `module/class` definitions; avoid nested styles

## Inherited Enterprise Layer Notes

- Chatwoot has an inherited `enterprise/` code split under `enterprise/` that extends/overrides OSS code.
- In Onelink, enterprise capabilities are currently opened for the project, so treat `enterprise/` as a technical repository/runtime layer rather than as a real product or paywall boundary.
- When you add or modify core functionality, always check for corresponding files in `enterprise/` and keep behavior compatible.
- For Onelink planning, treat `enterprise/` primarily as an existing technical overlay/extension mechanism. Do not use it as the conceptual boundary for domain architecture.
- Follow the Enterprise development practices documented here:
  - https://chatwoot.help/hc/handbook/articles/developing-enterprise-edition-features-38

Practical checklist for any change impacting core logic or public APIs
- Search for related files in both trees before editing (e.g., `rg -n "FooService|ControllerName|ModelName" app enterprise`).
- If adding new endpoints, services, or models, consider whether Enterprise needs:
  - An override (e.g., `enterprise/app/...`), or
  - An extension point (e.g., `prepend_mod_with`, hooks, configuration) to avoid hard forks.
- Avoid reintroducing OSS-vs-Enterprise product gating in Onelink code; if you need capability control, make it explicit at the product/account level instead of leaning on inherited paywall assumptions.
- Keep request/response contracts stable across `app/` and `enterprise/`; update both sets of routes/controllers when introducing new APIs.
- When renaming/moving shared code, mirror the change in `enterprise/` to prevent drift.
- Tests: Add `spec/enterprise` coverage when behavior is specific to inherited `enterprise/` paths, mirroring OSS spec layout where applicable.
- When modifying existing OSS features for behavior that currently lives only in the inherited `enterprise/` tree, add an `enterprise/` module (via `prepend_mod_with`/`include_mod_with`) instead of editing OSS files directly, especially for policies, controllers, and services. If a surface still exists only under `enterprise/`, place the code there until it is intentionally promoted into shared code.

## Branding / White-labeling note

- For user-facing strings that currently contain "Chatwoot" but should adapt to branded/self-hosted installs, prefer applying `replaceInstallationName` from `shared/composables/useBranding` in the UI layer (for example tooltip and suggestion labels) instead of adding hardcoded brand-specific copy.

## Repository Notes

- `CLAUDE.md` is a symlink to `AGENTS.md`, so updating this file updates both instruction entrypoints.
- This repo has a lightweight local dev path:
  - App processes run locally: Rails + Vite
  - Infra runs separately: Postgres + Redis
  - Only start Sidekiq when working on jobs, async flows, or features that require background processing
