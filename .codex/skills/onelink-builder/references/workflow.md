# Onelink Workflow

## Toolchain

- Ruby: `3.4.4`
- Node: `24.13.0`
- Package manager: `pnpm@10`
- Default app ports: Rails `3000`, Vite `3036`

## Setup and Run

- Install deps: `bundle install && pnpm install`
- Preferred full dev run: `pnpm dev` or `overmind start -f ./Procfile.dev`
- Preferred light run: `pnpm dev:lite` or `foreman start -f ./Procfile.dev-lite`
- Fast reset path: `./bin/dev-lite-restart`
- Rebuild DB state after schema/setup changes: `PREPARE_DB=1 ./bin/dev-lite-restart`
- Enterprise bootstrap options:
  - Dev-lite restart reapplies Enterprise mode by default; opt out with `CW_BOOTSTRAP_ENTERPRISE=0 ./bin/dev-lite-restart`
  - Manual bootstrap in non-test env: `bundle exec rake chatwoot:instance:unlock_enterprise`
  - Auto-bootstrap during prepare: `CW_BOOTSTRAP_ENTERPRISE=1 bundle exec rake db:chatwoot_prepare`
  - Optional plan label override: `CW_BOOTSTRAP_ACCOUNT_PLAN_NAME=Enterprise`
- Dev-lite infra path from repo guidance:
  - `colima start --cpu 2 --memory 4 --disk 20` if Docker Desktop is not available
  - `export DOCKER_HOST=unix:///Users/akhanbakhitov/.colima/default/docker.sock`
  - `docker compose up -d postgres redis`
  - `bundle exec rake db:chatwoot_prepare`
- Open the app at `http://127.0.0.1:3000` so HMR matches the configured Vite host.
- Seed data options:
  - Minimal local seed: `bundle exec rails db:seed`
  - Search/perf fixtures: `bundle exec rails search:setup_test_data`
  - Rich account sample data: `bundle exec rails runner "Internal::SeedAccountJob.perform_now(Account.find(<id>))"`

## Verification

- Ruby tests: `bundle exec rspec spec/path/to/file_spec.rb`
- Single Ruby example: `bundle exec rspec spec/path/to/file_spec.rb:LINE`
- JS tests: `pnpm test`
- JS watch: `pnpm test:watch`
- JS lint: `pnpm eslint`
- Ruby lint: `bundle exec rubocop -a`
- Swagger build after API doc changes: `bundle exec rake swagger:build`
- Widget/manual UI checks:
  - app: `http://127.0.0.1:3000`
  - widget tests: `http://127.0.0.1:3000/widget_tests`

## Git and Branching

- Primary branch: `onelink-main`
- Do not treat `develop` in this fork as the base product branch.
- Remotes:
  - `origin`: `git@github.com:demomastra2025-eng/chatwoot.git`
  - `upstream`: `https://github.com/chatwoot/chatwoot.git`
- Push to `origin` over SSH.
- Docs live in the separate `onelink-docs` repository mounted at `onelink/docs`; commit docs content there first, then update the submodule pointer in the parent `onelink` repo.
- For upstream sync work, branch from `onelink-main`, merge upstream tags or selected upstream branches into a dedicated sync branch, then validate before merging back.
- Prefer Conventional Commit messages: `type(scope): subject`

## Worktree Workflow

- Prefer a separate git worktree plus branch per task to isolate changes.
- Keep Codex-specific local setup under `.codex/`.
- Use `Procfile.worktree` when operating in a worktree-oriented local setup.
- Expect per-worktree DB/port/Redis values from `.codex/environments/environment.toml` to avoid collisions.
- Start each worktree with its own Overmind socket/title.
- If using a worktree, preserve the same remote layout: `origin` over SSH and `upstream` pointing to Chatwoot.

## Coding Rules

- Use Composition API with `<script setup>` in Vue files.
- Avoid bare strings in Vue templates; use i18n.
- Use Tailwind utilities only. Avoid custom CSS, scoped CSS, and inline styles.
- Keep changes minimal and readable; optimize for happy path first.
- Avoid unnecessary specs unless the user explicitly asks for them.
- Remove dead code instead of layering parallel implementations.
- Frontend translations: update English JSON only.
- Backend translations: update English YAML only.
- Prefer `with_modified_env` in specs over direct `ENV` stubbing.
- In specs running across reload/parallel boundaries, prefer asserting `error.class.name` over constant class equality.
- In Ruby, prefer compact `module/class` definitions over nested styles.
- Use repo conventions for validations, indexes, strong params, and custom exceptions instead of ad hoc patterns.

## Enterprise and Extension Safety

- Search in both `app` and `enterprise` before modifying shared logic.
- Prefer extension points over embedding Enterprise-specific branching in OSS code.
- Mirror route, contract, and service changes where Enterprise depends on them.
- For Enterprise-only behavior in shared features, prefer `prepend_mod_with` or `include_mod_with` modules over editing OSS files directly.

## Practical Heuristics

- Start broad tasks with `onelink-builder`, then switch to the matching specialized skill when the task surface is clear.
- If a task changes skill definitions, update the versioned project copy under `onelink/.codex/skills` and then sync to `$CODEX_HOME/skills` with `./.codex/scripts/sync-skills.sh to-codex-home`.
- For docs tasks, read `onelink/docs/AGENTS.md`, `platform/repository-map.mdx`, `project-operations.mdx`, and `docs-repository-workflow.mdx`.
- Choose dev-lite unless the feature depends on jobs, cron, async mailers, or background processing.
- If the task touches channels, start by reading existing service folders and docs for channel constraints instead of designing from scratch.
- If the task adds an endpoint, check controller, route, serializer/builder, policy, request spec pattern, and `swagger/`.
- If the task touches AI/Captain, inspect models, services, `config/agents/tools.yml`, and Enterprise prompt/tool files together.
- If a user-facing UI string mentions `Chatwoot` but should respect white-labeling, use `replaceInstallationName` from `shared/composables/useBranding` instead of hardcoding brand text.
