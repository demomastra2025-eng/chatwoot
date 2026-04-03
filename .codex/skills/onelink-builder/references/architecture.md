# Onelink Architecture

## Stack

- Rails 7.1 monolith on Ruby 3.4.4.
- Vue 3 frontend built with Vite 5, `vite-plugin-ruby`, pnpm 10, Tailwind 3, Vitest, and ESLint.
- Postgres 16 with `pgvector`, Redis, Sidekiq, ActionCable, and a large service-object layer.
- Current working branch and intended base branch are `onelink-main`.
- The repository still maintains an upstream sync path, but daily product work should be reasoned about as One Link Cloud rather than as an upstream patch layer.

## Repository Shape

- `app/`: main Rails app code.
- `app/javascript/`: frontend surfaces and shared UI code.
- `enterprise/`: Enterprise overlay that extends or overrides OSS behavior.
- `lib/`: integrations, Captain helpers, custom exceptions, seeders, tasks, and shared infrastructure code.
- `swagger/`: OpenAPI source files.
- `docs/`: separate Mintlify docs repository embedded in the app repo as a submodule.
- `$CODEX_HOME/skills`: local Codex skill library for workspace-specific instructions.

## Frontend Surfaces

- Entrypoints live in `app/javascript/entrypoints/`: `dashboard.js`, `widget.js`, `portal.js`, `survey.js`, `sdk.js`, `superadmin.js`, `superadmin_pages.js`, `v3app.js`.
- Main frontend directories:
  - `dashboard/`: agent-facing application UI.
  - `widget/`: customer chat widget.
  - `portal/`: help center frontend.
  - `survey/`: CSAT/survey frontend.
  - `superadmin_pages/`: super admin UI.
  - `shared/`: shared frontend helpers/components.
- Vite aliases map key areas such as `dashboard`, `widget`, `survey`, `shared`, `v3`, `components`, and `next`.
- `dashboard` boots with Pinia, but legacy store patterns still exist. `survey`, `v3`, `widget`, and parts of `dashboard/store` still use older store conventions. Do not assume every area is pure Pinia.
- Message-bubble work should prefer `app/javascript/dashboard/components-next/`.

## Runtime And Ownership Surfaces

- Main app code, specs, migrations, routes, and deployment assets live in `onelink`.
- Docs content, `docs/docs.json`, and local OpenAPI files live in `onelink/docs`.
- Versioned project skills live in `onelink/.codex/skills`.
- Installed Codex runtime skills live in `$CODEX_HOME/skills`.

The practical ownership rule is:

- app behavior: `onelink`
- docs behavior and docs structure: `onelink/docs`
- versioned skill source: `onelink/.codex/skills`
- installed agent runtime guidance: `$CODEX_HOME/skills`

## Backend Domains

- Core models/tables include `accounts`, `users`, `contacts`, `contact_inboxes`, `inboxes`, `conversations`, `messages`, `labels`, `macros`, `notifications`, `teams`, `campaigns`, `automation_rules`, `articles`, `portals`, `working_hours`, `custom_attribute_definitions`, `custom_filters`, `dashboard_apps`, and `webhooks`.
- Newer product areas include `assignment_policies`, `inbox_assignment_policies`, `agent_capacity_policies`, `companies`, `sla_policies`, `applied_slas`, and `reporting_events`.
- AI/Captain-related tables include `captain_assistants`, `captain_documents`, `captain_scenarios`, `captain_custom_tools`, `captain_assistant_responses`, `captain_inboxes`, `copilot_threads`, and `copilot_messages`.
- Service objects are grouped heavily under `app/services/`, including `conversations`, `contacts`, `messages`, `automation_rules`, `auto_assignment`, `message_templates`, `mailbox`, `notification`, `crm`, and per-channel folders such as `whatsapp`, `instagram`, `twilio`, `sms`, `telegram`, `line`, `facebook`, `tiktok`, and `email`.

## API Surfaces

- `api/v1`: main application JSON API for accounts, inboxes, conversations, contacts, Captain, integrations, portals, webhooks, and more.
- `api/v2`: reports and summary reporting endpoints.
- `platform/api/v1`: provisioning-style APIs for users, accounts, account users, and agent bots.
- `public/api/v1`: client-facing contact, conversation, message, and CSAT APIs.
- Enterprise API v1 surface: Enterprise-only endpoints.
- Other route groups include `survey`, `super_admin`, `installation`, third-party callbacks, and widget test routes.
- API documentation source lives under `swagger/`; changes should keep OpenAPI docs aligned.

## Omnichannel and Product Map

- Supported conversation channels include website chat, API, email, Facebook, Instagram, SMS, WhatsApp, Telegram, Line, and TikTok.
- Channel-specific behavior is implemented in services plus inbox/channel models and controllers. Check existing provider-specific folders before adding new abstractions.
- Help center lives across `article`, `category`, `portal`, related controllers, and frontend `portal/`.
- Feature flags live in `config/features.yml`; use them instead of hardcoding plan- or rollout-specific behavior.
- Treat One Link as one shared cloud platform. Customer variation should come from access, configuration, custom fields, automation, integrations, and Captain setup rather than separate domain runtimes.

## Captain and AI

- OpenAI/Agents SDK wiring is configured in `config/initializers/ai_agents.rb` using installation config values.
- Captain tool registry lives in `config/agents/tools.yml`.
- Prompting and Enterprise-specific Captain logic also appear under `enterprise/lib/captain/` and `enterprise/lib/enterprise/captain/`.
- If the task touches Captain, inspect both OSS and Enterprise trees before changing data contracts or execution flow.

## Enterprise Overlay

- `config/initializers/01_inject_enterprise_edition_module.rb` provides `prepend_mod_with`, `include_mod_with`, and `extend_mod_with`.
- Shared behavior may be extended from `enterprise/app/`, `enterprise/config/`, or `enterprise/lib/`.
- For core feature work, search both trees up front to avoid breaking Enterprise.
