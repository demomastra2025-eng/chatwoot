# Chatwoot 4.14 → OneLink Architectural Adoption Plan

> **For Hermes / dev team:** this is a planning document only. Do not implement by bulk merge. Use this plan task-by-task, with path-limited commits and targeted verification.

**Goal:** перенять полезные изменения Chatwoot `v4.14.0` после уже перенесённой базы `v4.13.0`, сохранив OneLink как нативный, системный, надёжный продуктовый форк.

**Главное правило:** мы **не копируем upstream wholesale** и **не делаем слепой merge**. Мы перенимаем **идеи, функции, fixes и тестовые сценарии**, затем адаптируем их архитектурно правильно в OneLink: через существующие OneLink сущности, enterprise overlays, account-scoped access, Captain/AI Voice/WhatsApp/Fonoster runtime и текущие product conventions.

**Source baseline:**
- Upstream example repo: `/root/crafty/example/chatwoot`
- Upstream diff: `v4.13.0..v4.14.0`
- OneLink repo: `/root/crafty/onelink/chatwoot`
- OneLink current branch at analysis time: `feature/content-postiz-native-module`
- OneLink already contains `origin/sync/chatwoot-v4.13.0-carry` as ancestor, so this plan is only for `4.13 → 4.14` delta.

**Non-goals:**
- No production deploy/restart/service change in this plan.
- No broad branch merge from upstream `develop`.
- No replacement of OneLink Captain/RAG/AI Voice/Fonoster/WhatsApp Calls architecture with upstream enterprise voice/Captain defaults.

---

## 0. Operating Principles For The Team

### 0.1 Architectural adoption rule

For every upstream change:

1. Identify the upstream intent:
   - security hardening
   - bug fix
   - product UX
   - API contract
   - dependency/CVE update
   - test-only scenario
2. Identify the OneLink-owned runtime path:
   - `app/`
   - `enterprise/`
   - `app/javascript/`
   - `config/`
   - `db/`
   - sidecar/runtime service if applicable
3. Decide whether to:
   - adopt directly;
   - adapt with OneLink-specific shape;
   - take only tests/edge cases;
   - reject because it conflicts with OneLink architecture.
4. Add or adapt tests before calling the task done.
5. Keep commits path-limited and phase-scoped.

### 0.2 Preserve OneLink architecture

Mandatory constraints:

- Reuse native OneLink/Chatwoot entities first: `Account`, `Inbox`, `Conversation`, `Message`, `Contact`, `Company`, `AutomationRule`, `Integrations::Hook`, Captain models, CRM entities, Telephony models.
- Preserve `enterprise/` overlays and check both OSS + enterprise paths before touching shared behavior.
- Preserve OneLink Captain architecture:
  - native tools;
  - account-aware LLM routing;
  - OpenRouter/account keys;
  - RAG/document chunks/retrieval traces;
  - confirmation gates;
  - AI Voice tool dispatch.
- Preserve OneLink Voice/Telephony architecture:
  - Fonoster `Channel::Voice`;
  - `Telephony::*` models/services;
  - WhatsApp media-server relay flow;
  - AI Voice runtime/sidecar contracts.
- Preserve OneLink product terminology/white-labeling.

### 0.3 Git and safety rules

- Start from a clean/snapshotted status; do not stage unrelated existing dirty files.
- Use one branch per phase or small group:
  - `fix/chatwoot-414-security-carry`
  - `fix/chatwoot-414-email-imap-carry`
  - `feat/chatwoot-414-contact-media-ui`
  - `feat/chatwoot-414-companies-crm-carry`
- Commit path-limited.
- Do not deploy/restart/migrate prod without explicit approval.
- For DB migrations: inspect current OneLink schema first; never apply upstream “repurpose feature flag” migrations blindly.

### 0.4 Verification defaults

Use narrow verification first:

```bash
# Ruby syntax for touched files
ruby -c path/to/file.rb

# Targeted RSpec, preferred in this OneLink environment if normal bundle env is flaky
./bin/dev-hybrid rspec spec/path/to/spec.rb --format progress

# Alternative explicit Ruby env
RBENV_ROOT=/root/.rbenv PATH=/root/.rbenv/bin:/root/.rbenv/shims:$PATH bundle exec rspec spec/path/to/spec.rb --format progress

# Frontend targeted checks
pnpm exec eslint app/javascript/path/File.vue app/javascript/path/helper.js
pnpm exec vitest --no-watch --no-cache --no-coverage app/javascript/path/spec.js

# General hygiene
git diff --check
git status --short --branch --untracked-files=all
```

---

## 1. Upstream Reference Map

### 1.1 Upstream scope summary

Command reference:

```bash
git -C /root/crafty/example/chatwoot log --reverse --no-merges --format='%h %ad %s' --date=short v4.13.0..v4.14.0
git -C /root/crafty/example/chatwoot diff --shortstat v4.13.0..v4.14.0
git -C /root/crafty/example/chatwoot diff --name-status v4.13.0..v4.14.0
```

Observed summary:
- `135` commits.
- `1595` files changed.
- `96968 insertions`, `18617 deletions`.
- Major areas:
  - `app/javascript/`
  - `enterprise/app/`
  - `config/locales/`
  - `spec/`
  - `db/migrate/`
  - dependencies.

### 1.2 OneLink current evidence from analysis

Important current OneLink evidence:

- `lib/webhooks/trigger.rb` still uses `RestClient::Request.execute`.
- `app/jobs/avatar/avatar_from_url_job.rb` still uses `Down.download`.
- `app/controllers/concerns/meta_token_verify_concern.rb` only handles verify-token, not HMAC body signature.
- `config/initializers/active_storage.rb` is absent.
- `app/controllers/swagger_controller.rb` reads joined path without root-bound cleanpath guard.
- `app/controllers/api/v1/accounts/custom_attribute_definitions_controller.rb` lacks `before_action :check_authorization`.
- `app/builders/notification_builder.rb` lacks conversation-access check via `ConversationPolicy`.
- `app/services/imap/base_fetch_email_service.rb` lacks `MAX_MESSAGES_PER_SYNC` cap and header-only early filtering.
- `enterprise/app/controllers/api/v1/accounts/whatsapp_calls_controller.rb` is already much wider than upstream and must not be replaced wholesale.
- OneLink has custom Captain RAG/document chunk architecture and must not adopt upstream Captain document sync schema/jobs wholesale.

---

## 2. Phase P0 — Security And Access Hardening

**Objective:** close security/access gaps from upstream `v4.14.0` first, with minimal product behavior changes.

**Branch suggestion:** `fix/chatwoot-414-security-carry`

### Task P0.1 — SafeFetch foundation for secure outbound HTTP

**Upstream refs:**
- `c8e551820` — SSRF fix for webhook trigger used by macros and automations.
- `661608c0b` — harden external downloads against SSRF for avatar-from-url job.

**Upstream files:**
- `/root/crafty/example/chatwoot/lib/safe_fetch.rb`
- `/root/crafty/example/chatwoot/lib/safe_fetch/fetcher.rb`
- `/root/crafty/example/chatwoot/lib/safe_fetch/request_options.rb`
- `/root/crafty/example/chatwoot/lib/webhooks/trigger.rb`
- `/root/crafty/example/chatwoot/app/jobs/avatar/avatar_from_url_job.rb`
- `/root/crafty/example/chatwoot/app/models/concerns/avatarable.rb`

**OneLink files likely to modify:**
- `lib/safe_fetch.rb`
- create/adapt: `lib/safe_fetch/fetcher.rb`
- create/adapt: `lib/safe_fetch/request_options.rb`
- `lib/webhooks/trigger.rb`
- `app/jobs/avatar/avatar_from_url_job.rb`
- `app/models/concerns/avatarable.rb`
- specs:
  - `spec/lib/safe_fetch_spec.rb`
  - `spec/lib/webhooks/trigger_spec.rb`
  - `spec/jobs/avatar/avatar_from_url_job_spec.rb`

**OneLink-specific design:**
- Do not blindly replace OneLink `SafeFetch`; preserve any local behavior and naming that exists.
- Extend it to support:
  - safe `GET` and `POST`;
  - body;
  - headers;
  - explicit method allowlist;
  - timeout;
  - max bytes;
  - content-type allowlist;
  - sensitive header handling;
  - redirect safety.
- Ensure webhook HMAC headers already added in OneLink stay intact:
  - `X-Chatwoot-Delivery`
  - `X-Chatwoot-Timestamp`
  - `X-Chatwoot-Signature`

**Acceptance:**
- Webhook trigger no longer calls `RestClient::Request.execute` directly.
- Avatar URL job no longer uses raw `Down.download` for arbitrary external URL.
- Tests cover private IP, localhost, redirect-to-private, unsupported content type, max bytes, POST body, headers, failure handling.

**Verification:**

```bash
ruby -c lib/safe_fetch.rb
ruby -c lib/safe_fetch/fetcher.rb
ruby -c lib/safe_fetch/request_options.rb
ruby -c lib/webhooks/trigger.rb
ruby -c app/jobs/avatar/avatar_from_url_job.rb
./bin/dev-hybrid rspec spec/lib/safe_fetch_spec.rb spec/lib/webhooks/trigger_spec.rb spec/jobs/avatar/avatar_from_url_job_spec.rb --format progress
git diff --check
```

### Task P0.2 — Meta webhook HMAC validation

**Upstream ref:**
- `a9ac1c633` — HMAC validation for WhatsApp and Instagram webhooks.

**Upstream files:**
- `/root/crafty/example/chatwoot/app/controllers/concerns/meta_token_verify_concern.rb`
- `/root/crafty/example/chatwoot/app/controllers/webhooks/whatsapp_controller.rb`
- `/root/crafty/example/chatwoot/app/controllers/webhooks/instagram_controller.rb`
- `/root/crafty/example/chatwoot/config/initializers/facebook_messenger.rb`
- specs under `spec/controllers/webhooks/`.

**OneLink files likely to modify:**
- `app/controllers/concerns/meta_token_verify_concern.rb`
- `app/controllers/webhooks/whatsapp_controller.rb`
- `app/controllers/webhooks/instagram_controller.rb`
- possibly provider config handling for WA/IG secrets.
- specs:
  - `spec/controllers/webhooks/whatsapp_controller_spec.rb`
  - `spec/controllers/webhooks/instagram_controller_spec.rb`

**OneLink-specific design:**
- Read secrets from the actual OneLink channel/provider config shape.
- Do not break Meta verification challenge endpoint.
- Keep logs sanitized; never log secrets or raw token values.
- Check whether OneLink Evolution/WA runtime sends standard Meta signature for direct Cloud webhooks; if not available for some internal callbacks, gate only public Meta endpoints and document exceptions.

**Acceptance:**
- Public WhatsApp/Instagram webhook payloads require valid `X-Hub-Signature-256` when app/channel secret exists.
- Verify-token challenge still works.
- Invalid signature returns unauthorized before enqueueing jobs.

**Verification:**

```bash
ruby -c app/controllers/concerns/meta_token_verify_concern.rb
ruby -c app/controllers/webhooks/whatsapp_controller.rb
ruby -c app/controllers/webhooks/instagram_controller.rb
./bin/dev-hybrid rspec spec/controllers/webhooks/whatsapp_controller_spec.rb spec/controllers/webhooks/instagram_controller_spec.rb --format progress
git diff --check
```

### Task P0.3 — ActiveStorage upload/proxy hardening

**Upstream ref:**
- `ffbf40c72` — harden Active Storage direct uploads and proxy streaming.

**Upstream files:**
- `/root/crafty/example/chatwoot/config/initializers/active_storage.rb`
- `/root/crafty/example/chatwoot/app/models/attachment.rb`

**OneLink files likely to modify/create:**
- create: `config/initializers/active_storage.rb`
- `app/models/attachment.rb`
- relevant attachment specs if present.

**OneLink-specific design:**
- Preserve audio inline behavior required for OneLink voice recordings and AI Voice playback.
- Add metadata key filtering:
  - `identified`
  - `analyzed`
  - `composed`
- Add range request limiting for streaming proxy.
- Confirm generated recording URLs still work in conversation bubbles.

**Acceptance:**
- Direct upload cannot set internal ActiveStorage metadata keys.
- Proxy streaming rejects multi-range or oversized range abuse.
- Voice/audio playback still renders inline.

**Verification:**

```bash
ruby -c config/initializers/active_storage.rb
ruby -c app/models/attachment.rb
./bin/dev-hybrid rspec spec/models/attachment_spec.rb --format progress
# Add/request specs if no existing coverage exists.
git diff --check
```

### Task P0.4 — Swagger path traversal fix

**Upstream ref:**
- `fbcb89e95` — prevent path traversal in docs controller.

**Upstream files:**
- `/root/crafty/example/chatwoot/app/controllers/swagger_controller.rb`
- `/root/crafty/example/chatwoot/spec/controllers/swagger_controller_spec.rb`

**OneLink files likely to modify:**
- `app/controllers/swagger_controller.rb`
- `spec/controllers/swagger_controller_spec.rb`

**OneLink-specific design:**
- Preserve OneLink `ENABLE_SWAGGER_UI` behavior if still needed.
- Add root-bound `cleanpath` guard so enabling Swagger UI cannot read outside `Rails.root/swagger`.

**Acceptance:**
- Normal swagger file loads in dev/test and when enabled as intended.
- `../` traversal returns not found.
- Production disabled behavior remains unchanged unless explicitly configured.

**Verification:**

```bash
ruby -c app/controllers/swagger_controller.rb
./bin/dev-hybrid rspec spec/controllers/swagger_controller_spec.rb --format progress
git diff --check
```

### Task P0.5 — Custom attribute definitions authorization

**Upstream ref:**
- `5c6ea78ce` — enforce admin authorization on custom attribute definitions API.

**Upstream files:**
- `/root/crafty/example/chatwoot/app/controllers/api/v1/accounts/custom_attribute_definitions_controller.rb`
- `/root/crafty/example/chatwoot/app/policies/custom_attribute_definition_policy.rb`
- `/root/crafty/example/chatwoot/spec/controllers/api/v1/accounts/custom_attribute_definitions_controller_spec.rb`

**OneLink files likely to modify/create:**
- `app/controllers/api/v1/accounts/custom_attribute_definitions_controller.rb`
- create: `app/policies/custom_attribute_definition_policy.rb`
- controller specs.

**OneLink-specific design:**
- Keep read access for agents if current product expects agents to use custom attributes.
- Restrict create/update/destroy to administrators.
- Check enterprise custom fields/CRM usage before tightening too far.

**Acceptance:**
- Admin can create/update/delete.
- Agent can list/show if expected.
- Agent cannot mutate definitions.

**Verification:**

```bash
ruby -c app/controllers/api/v1/accounts/custom_attribute_definitions_controller.rb
ruby -c app/policies/custom_attribute_definition_policy.rb
./bin/dev-hybrid rspec spec/controllers/api/v1/accounts/custom_attribute_definitions_controller_spec.rb --format progress
git diff --check
```

### Task P0.6 — Account/user/conversation scoping fixes

**Upstream ref:**
- `13f66e3a8` — incorrect scope across controllers.

**Upstream files:**
- `app/controllers/api/v1/accounts/inboxes_controller.rb`
- `app/controllers/api/v1/accounts/notifications_controller.rb`
- `app/controllers/api/v1/accounts/portals_controller.rb`
- `app/controllers/api/v1/notification_subscriptions_controller.rb`
- `app/controllers/api/v1/widget/messages_controller.rb`
- `app/controllers/public/api/v1/inboxes_controller.rb`
- `app/jobs/bulk_actions_job.rb`
- `app/jobs/notification/delete_notification_job.rb`
- related specs.

**OneLink files likely to modify:**
- Same paths in `/root/crafty/onelink/chatwoot`.
- Also inspect OneLink custom controllers for the same anti-pattern:
  - global `.find(params[:id])` where account-scoped lookup is required;
  - notification deletes not scoped to account/user;
  - widget/public paths crossing inbox/account boundaries;
  - bulk action jobs not filtering by permissions.

**OneLink-specific design:**
- Do not break OneLink custom bulk progress or Telegram/push behavior.
- Use `Conversations::PermissionFilterService` where conversation-level access matters.
- Keep public/widget endpoints scoped by inbox/contact-inbox tokens.

**Acceptance:**
- Cross-account IDs cannot be accessed/mutated.
- Agents cannot bulk-operate conversations they cannot see.
- Notification delete cannot delete another user/account notification.

**Verification:**

```bash
ruby -c app/controllers/api/v1/accounts/inboxes_controller.rb
ruby -c app/controllers/api/v1/accounts/notifications_controller.rb
ruby -c app/controllers/api/v1/accounts/portals_controller.rb
ruby -c app/controllers/api/v1/notification_subscriptions_controller.rb
ruby -c app/controllers/api/v1/widget/messages_controller.rb
ruby -c app/controllers/public/api/v1/inboxes_controller.rb
ruby -c app/jobs/bulk_actions_job.rb
ruby -c app/jobs/notification/delete_notification_job.rb
./bin/dev-hybrid rspec \
  spec/controllers/api/v1/accounts/inboxes_controller_spec.rb \
  spec/controllers/api/v1/accounts/notifications_controller_spec.rb \
  spec/controllers/api/v1/accounts/portals_controller_spec.rb \
  spec/controllers/api/v1/notification_subscriptions_controller_spec.rb \
  spec/controllers/api/v1/widget/messages_controller_spec.rb \
  spec/jobs/bulk_actions_job_spec.rb \
  spec/jobs/notification/delete_notification_job_spec.rb \
  --format progress
git diff --check
```

### Task P0.7 — Respect conversation access in notifications

**Upstream ref:**
- `6c67eb9ba` — notifications respect conversation access.

**Upstream files:**
- `/root/crafty/example/chatwoot/app/builders/notification_builder.rb`
- `/root/crafty/example/chatwoot/app/services/messages/mention_service.rb`
- specs around notification builder/mentions.

**OneLink files likely to modify:**
- `app/builders/notification_builder.rb`
- `app/services/messages/mention_service.rb`
- relevant specs.

**OneLink-specific design:**
- Keep OneLink extra notification channels (`telegram_*`) intact.
- Use `ConversationPolicy` with correct `account_user` context.
- For non-conversation primary actors, preserve existing behavior.

**Acceptance:**
- No notification for user who cannot access the conversation.
- Existing self/blocked/subscription behavior remains.
- Telegram/email/push notification settings still work.

**Verification:**

```bash
ruby -c app/builders/notification_builder.rb
ruby -c app/services/messages/mention_service.rb
./bin/dev-hybrid rspec spec/builders/notification_builder_spec.rb spec/services/messages/mention_service_spec.rb --format progress
git diff --check
```

---

## 3. Phase P1 — Backend Correctness, Email, IMAP, CSV, Dependencies

**Objective:** adopt low/medium-risk correctness fixes that reduce operational noise and improve enterprise reliability.

**Branch suggestion:** `fix/chatwoot-414-backend-correctness-carry`

### Task P1.1 — IMAP fetch cap and early filtering

**Upstream ref:**
- `a01adf860` — limit emails fetch.

**Files:**
- `app/services/imap/base_fetch_email_service.rb`
- specs for IMAP fetch service.

**Design:**
- Add `MAX_MESSAGES_PER_SYNC = 500` or configurable OneLink value if needed.
- Use header-only filtering to skip already imported and Chatwoot-generated notification emails before fetching bodies.

**Acceptance:**
- Heavy inbox cannot fetch unbounded bodies in one run.
- Already imported emails are skipped before body fetch.

**Verification:**

```bash
ruby -c app/services/imap/base_fetch_email_service.rb
./bin/dev-hybrid rspec spec/services/imap/fetch_email_service_spec.rb --format progress
```

### Task P1.2 — IMAP authentication type

**Upstream ref:**
- `202403873` — ability to specify authentication type for IMAP server.

**Upstream files:**
- `app/services/imap/authentication.rb`
- `app/models/channel/email.rb`
- `app/javascript/dashboard/routes/dashboard/settings/inbox/ImapSettings.vue`
- `app/views/api/v1/models/_inbox.json.jbuilder`
- migration `20260507000000_add_imap_authentication_to_channel_email.rb`.

**Design:**
- Add the backend field only after checking OneLink current `channel_email` schema.
- Keep default behavior compatible with existing inboxes.
- Expose UI in a minimal, localized way.

**Acceptance:**
- Existing IMAP inboxes continue using default auth.
- New/edited inbox can choose supported auth type.
- API serializes/deserializes the value.

**Verification:**

```bash
ruby -c app/models/channel/email.rb
ruby -c app/services/imap/authentication.rb
ruby -c app/services/imap/base_fetch_email_service.rb
./bin/dev-hybrid rspec spec/services/imap/fetch_email_service_spec.rb spec/controllers/api/v1/accounts/inboxes_controller_spec.rb --format progress
pnpm exec eslint app/javascript/dashboard/routes/dashboard/settings/inbox/ImapSettings.vue
```

### Task P1.3 — Email and CSV correctness pack

**Upstream refs:**
- `7d42edd17` — sanitize parentheses from email From header.
- `9a89e1f52` — strip UTF-8 BOM in `DataImportJob#csv_reader`.
- `c5fb8d73c` — prepend UTF-8 BOM to contact CSV export.
- `42bba748c` — render inline email images without `Content-Disposition`.
- `735bc73c9` — preserve single newlines in outgoing email messages.
- `c1d167bd6` — prevent `--` signature delimiter rendering as `\` in bubble.

**Likely files:**
- `app/builders/email/base_builder.rb`
- `app/mailers/conversation_reply_mailer.rb`
- `app/models/inbox.rb`
- `app/jobs/data_import_job.rb`
- `app/jobs/account/contacts_export_job.rb`
- `app/mailboxes/mailbox_helper.rb`
- `app/mailboxes/mailbox_inline_attachment_helper.rb`
- message rendering helpers/specs.

**Design:**
- Keep OneLink email branding and custom signatures.
- Add regression specs for Cyrillic/non-ASCII CSV and email headers.
- Ensure no customer-visible OneLink copy regresses to Chatwoot branding.

**Verification:**

```bash
ruby -c app/jobs/data_import_job.rb
ruby -c app/jobs/account/contacts_export_job.rb
ruby -c app/models/inbox.rb
./bin/dev-hybrid rspec \
  spec/jobs/data_import_job_spec.rb \
  spec/jobs/account/contacts_export_job_spec.rb \
  spec/mailers/conversation_reply_mailer_spec.rb \
  spec/mailboxes/mailbox_helper_spec.rb \
  --format progress
```

### Task P1.4 — Help center markdown/embed escaping

**Upstream ref:**
- `2192af80f` — html-escape captured values in helpcenter article markdown embeds.

**Files:**
- `lib/custom_markdown_renderer.rb`
- related renderer specs.

**Design:**
- Apply escaping only where HTML embed capture values are inserted.
- Do not break intended safe markdown rendering.

**Verification:**

```bash
ruby -c lib/custom_markdown_renderer.rb
./bin/dev-hybrid rspec spec/lib/custom_markdown_renderer_spec.rb --format progress
```

### Task P1.5 — Dependency security bump pack

**Upstream refs:**
- `bcdb73502` — `addressable 2.8.7 -> 2.9.0`
- `deb259c8d` — `rack 3.2.5 -> 3.2.6`
- `dd52f1d32` — `rack-session 2.1.1 -> 2.1.2`
- `79a7423f9` — `nokogiri 1.19.1 -> 1.19.3`
- `cfc7699b7` — `net-imap 0.4.20 -> 0.4.24`
- `9c8cfc40b` — `dompurify 3.3.2 -> 3.4.0`
- `8d7e926e0` — `video.js 7.18.1 -> 7.21.1`
- `517b67dfd` also updates template preview-related JS packages indirectly.

**OneLink current note:**
- `ruby_llm` is already `1.15.0`.
- `ruby_llm-schema` is already `0.4.0`, newer than upstream 4.14.
- Do not downgrade RubyLLM ecosystem.

**Files:**
- `Gemfile`
- `Gemfile.lock`
- `package.json`
- `pnpm-lock.yaml`

**Design:**
- Update minimal dependency set, not full ecosystem.
- Use temp/bundler resolution first if conflicts are likely.
- Do not accept accidental major framework upgrades.

**Verification:**

```bash
bundle exec bundle-audit check --update || true
bundle exec rspec spec/lib/safe_fetch_spec.rb spec/services/imap/fetch_email_service_spec.rb --format progress
pnpm exec eslint app/javascript/dashboard --max-warnings=0 # if feasible, otherwise touched files only
pnpm exec vitest --no-watch --no-cache --no-coverage path/to/touched/spec.js
```

---

## 4. Phase P2 — Operator/Product UX Improvements

**Objective:** adopt high-value user-facing functionality after security/correctness is stable.

**Branch suggestion:** `feat/chatwoot-414-operator-ux-carry`

### Task P2.1 — Contact attachments endpoint and sidebar media

**Upstream refs:**
- `dc332dd93` — attachments endpoint for contact media view.
- `8f532f45` — attachments section to conversation sidebar.

**Upstream files:**
- `app/controllers/api/v1/accounts/contacts/attachments_controller.rb`
- `app/views/api/v1/accounts/contacts/attachments/index.json.jbuilder`
- `app/views/api/v1/models/_attachment.json.jbuilder`
- `app/javascript/dashboard/routes/dashboard/conversation/ContactPanel.vue`
- `app/javascript/dashboard/routes/dashboard/conversation/SharedFiles.vue`
- `app/javascript/dashboard/store/modules/conversations/getters.js`

**OneLink design:**
- Keep OneLink conversation sidebar customizations: CRM, payments, AI/voice cards, touches.
- Scope attachments by account/contact/conversation access.
- Reuse existing attachment serializers and file access policies.

**Acceptance:**
- Operator sees contact/conversation shared media/files.
- No cross-account/contact leakage.
- Sidebar layout remains stable with OneLink custom panels.

**Verification:**

```bash
ruby -c app/controllers/api/v1/accounts/contacts/attachments_controller.rb
./bin/dev-hybrid rspec spec/controllers/api/v1/accounts/contacts/attachments_controller_spec.rb --format progress
pnpm exec eslint app/javascript/dashboard/routes/dashboard/conversation/ContactPanel.vue app/javascript/dashboard/routes/dashboard/conversation/SharedFiles.vue
pnpm exec vitest --no-watch --no-cache --no-coverage app/javascript/dashboard/store/modules/specs/conversations/getters.spec.js
```

### Task P2.2 — Rich template preview for WhatsApp/Twilio templates

**Upstream ref:**
- `517b67dfd` — rich template preview for WhatsApp & Twilio templates.

**Upstream files:**
- `app/javascript/dashboard/components-next/template-preview/*`
- `app/javascript/dashboard/services/TemplateNormalizer.js`
- `app/javascript/dashboard/services/TemplateTypeDetector.js`
- `app/javascript/dashboard/components-next/message/bubbles/Template/*`

**OneLink design:**
- Preserve OneLink WA Cloud/WA Web/template flows.
- Localize RU/EN labels.
- Keep preview components framework-native and reusable, not provider-specific hacks.

**Acceptance:**
- WhatsApp template previews render header/body/buttons/media states correctly.
- Twilio templates still render if supported.
- Existing message bubble behavior remains stable.

**Verification:**

```bash
pnpm exec eslint app/javascript/dashboard/components-next/template-preview app/javascript/dashboard/services/TemplateNormalizer.js app/javascript/dashboard/services/TemplateTypeDetector.js
pnpm exec vitest --no-watch --no-cache --no-coverage app/javascript/dashboard/services/specs/TemplateNormalizer.spec.js app/javascript/dashboard/services/specs/TemplateTypeDetector.spec.js
```

### Task P2.3 — WhatsApp campaign variables

**Upstream ref:**
- `f8f0caf44` — variable support to WhatsApp campaigns.

**Upstream files:**
- `app/services/whatsapp/liquid_template_processor_service.rb`
- `app/services/whatsapp/oneoff_campaign_service.rb`
- related specs.

**OneLink design:**
- Align with OneLink outbound CRM/touch campaign semantics.
- Avoid unsafe Liquid evaluation.
- Define supported variables explicitly: contact, inbox, account, conversation where applicable.

**Acceptance:**
- Campaign messages can render approved variables.
- Missing variable behavior is deterministic and tested.
- No arbitrary object access leaks.

**Verification:**

```bash
ruby -c app/services/whatsapp/liquid_template_processor_service.rb
ruby -c app/services/whatsapp/oneoff_campaign_service.rb
./bin/dev-hybrid rspec spec/services/whatsapp/liquid_template_processor_service_spec.rb spec/services/whatsapp/oneoff_campaign_service_spec.rb --format progress
```

### Task P2.4 — Conversation bulk action UI refresh

**Upstream refs:**
- `2435d7503` — update conversation bulk action UI.
- `85ddc688` — prevent bulk action checkbox reset in team view.

**Likely files:**
- `app/javascript/dashboard/components/widgets/conversation/conversationBulkActions/*`
- `app/javascript/dashboard/composables/chatlist/useBulkActions.js`
- `app/javascript/dashboard/components/ChatList.vue`

**OneLink design:**
- Preserve OneLink conversation filters, CRM/AI/voice context, and sidebar states.
- Do not adopt large layout rewrite if it conflicts with current UX.

**Acceptance:**
- Bulk select/actions work in inbox/team/custom views.
- Checkbox selection does not reset unexpectedly.
- Keyboard/mouse interactions remain predictable.

**Verification:**

```bash
pnpm exec eslint app/javascript/dashboard/components/widgets/conversation/conversationBulkActions app/javascript/dashboard/composables/chatlist/useBulkActions.js app/javascript/dashboard/components/ChatList.vue
pnpm exec vitest --no-watch --no-cache --no-coverage app/javascript/dashboard/composables/chatlist/useBulkActions.spec.js
```

### Task P2.5 — Platform-wide status banners

**Upstream refs:**
- `5325e0514` — platform-wide status banners.
- `e723c6b6f` — prevent cloud check from breaking app boot.

**Files:**
- `app/models/platform_banner.rb`
- `app/controllers/super_admin/platform_banners_controller.rb`
- `app/javascript/dashboard/components/app/StatusBanner.vue`
- `app/javascript/shared/store/globalConfig.js`
- migration `create_platform_banners`.

**OneLink design:**
- White-label copy: no Chatwoot-specific wording.
- Account for OneLink Cloud multi-tenant admin flow.
- Banners should degrade safely if cloud/status config fails.

**Acceptance:**
- Super Admin can manage status banners.
- Dashboard shows active banners.
- Broken external check cannot break app boot.

**Verification:**

```bash
ruby -c app/models/platform_banner.rb
ruby -c app/controllers/super_admin/platform_banners_controller.rb
./bin/dev-hybrid rspec spec/models/platform_banner_spec.rb spec/controllers/super_admin/platform_banners_controller_spec.rb --format progress
pnpm exec eslint app/javascript/dashboard/components/app/StatusBanner.vue app/javascript/shared/store/globalConfig.js
```

### Task P2.6 — Super Admin push diagnostics

**Upstream ref:**
- `6a9c44476` — super-admin push diagnostics tool.

**Files:**
- `app/controllers/super_admin/push_diagnostics_controller.rb`
- `app/services/notification/push_test_service.rb`
- `app/views/super_admin/push_diagnostics/show.html.erb`

**OneLink design:**
- Keep tool admin-only.
- Redact tokens/device secrets in logs/views.
- Useful for support RCA without production console access.

**Verification:**

```bash
ruby -c app/controllers/super_admin/push_diagnostics_controller.rb
ruby -c app/services/notification/push_test_service.rb
./bin/dev-hybrid rspec spec/services/notification/push_test_service_spec.rb spec/controllers/super_admin/push_diagnostics_controller_spec.rb --format progress
```

---

## 5. Phase P3 — Integrations Carry

**Objective:** adopt integration-specific improvements only if the integration is active or strategically important.

### Task P3.1 — TikTok media upload and attachment capability gating

**Upstream ref:**
- `b8108b71` — TikTok media upload failures and attachment capability gating.

**Files:**
- `app/services/tiktok/client.rb`
- `app/services/tiktok/messaging_helpers.rb`
- `app/services/tiktok/send_on_tiktok_service.rb`
- `app/javascript/dashboard/components/widgets/conversation/ReplyBox.vue`

**Design:**
- Preserve OneLink attachment UX.
- Gate composer attachments by actual conversation/channel capability.

### Task P3.2 — Slack interaction sync and emoji formatting

**Upstream refs:**
- `f7bbd408` — Slack bot interactive responses sync.
- `80fccbc5` — render Slack emoji shortcodes as unicode.

**Files:**
- `app/jobs/hook_job.rb`
- `app/listeners/hook_listener.rb`
- `lib/integrations/slack/update_slack_message_service.rb`
- `lib/integrations/slack/emoji_formatter.rb`
- `lib/integrations/slack/slack_message_helper.rb`

**Design:**
- Adopt only if Slack app is enabled/used.
- Keep webhook/agent bot failure handling from P0 intact.

### Task P3.3 — Linear auto-link from private notes

**Upstream ref:**
- `71cc5168` — auto-link Linear issues from private notes.

**Files:**
- `app/jobs/hook_job.rb`
- `app/listeners/hook_listener.rb`
- `lib/integrations/linear/auto_link_service.rb`
- `lib/linear/queries.rb`

**Design:**
- Useful for internal/product ops, but should not leak private note content externally unless integration is explicitly installed and authorized.
- Add audit/logging with no token leakage.

---

## 6. Phase P4 — CRM Companies Epic

**Objective:** adopt Companies improvements as a dedicated CRM product project, not as part of security carry.

**Upstream refs:**
- `fe44b071` — company detail page.
- `10597863` — company creation flow.
- `086aa36f` — notes and history in company details.
- `1d2f3e86` — company last activity.

**Upstream files:**
- `app/javascript/dashboard/components-next/Companies/*`
- `app/javascript/dashboard/routes/dashboard/companies/*`
- `app/javascript/dashboard/stores/companies.js`
- `enterprise/app/controllers/api/v1/accounts/companies/*`
- `enterprise/app/models/company.rb`
- `enterprise/app/services/companies/contact_membership_service.rb`
- migrations for company attrs/activity.

**OneLink design:**
- Treat as CRM feature epic.
- Align with existing OneLink CRM deals/tasks/pipelines/custom fields.
- Avoid duplicating company-contact relationship logic if OneLink CRM already extends it.
- Preserve enterprise/account scoping.

**Implementation outline:**

1. Audit current OneLink Companies + CRM relationship model.
2. Add backend/API changes with request specs.
3. Add company detail page route and store changes.
4. Add contacts sidebar/membership actions.
5. Add company notes/history integration.
6. Add last activity calculation/update path.
7. Add docs/internal note if entity meaning changes.

**Verification:**

```bash
./bin/dev-hybrid rspec spec/enterprise/controllers/api/v1/accounts/companies_controller_spec.rb spec/enterprise/controllers/api/v1/accounts/companies/contacts_controller_spec.rb --format progress
pnpm exec eslint app/javascript/dashboard/components-next/Companies app/javascript/dashboard/routes/dashboard/companies app/javascript/dashboard/stores/companies.js
pnpm exec vitest --no-watch --no-cache --no-coverage app/javascript/dashboard/stores/companies.spec.js
```

---

## 7. Captain/AI Adoption Rules

**Objective:** use upstream Captain changes as references, not as direct replacement.

### 7.1 Accept/adapt selectively

**OpenAI hook validation**
- Upstream ref: `3253e863e`.
- Adopt concept, but make it provider-aware:
  - OpenAI direct key;
  - OpenRouter key/model routing;
  - account-level keys;
  - global fallback settings.

**LLM settings refresh warning UX**
- Upstream ref: `059d84027`.
- OneLink already refreshes some LLM settings.
- Adopt only operator UX/warning for restart-required keys if useful.

**FAQ/datetime prompt improvements**
- Upstream refs:
  - `a651949c3`
  - `279dd1876`
- Use as prompt/test references only.
- Compare with OneLink `enterprise/app/services/captain/llm/system_prompts_service.rb` and PromptRegistry.

**Article translation via LLM**
- Upstream ref: `751c28d94`.
- Optional help-center feature, separate from Captain runtime.
- Must include cost/rate-limit/account routing policy.

### 7.2 Do not adopt wholesale

**Do not adopt upstream Captain document auto-sync schema/jobs wholesale.**

Refs:
- `568aae875`
- `f6be0d80e`
- `d00867d63`
- `d7d1e4113`

Reason:
- OneLink has custom document source modes, `Captain::DocumentChunk`, embeddings, retrieval traces, RAG eval gates.
- Upstream metadata/scheduler could corrupt or bypass OneLink RAG pipeline.

Acceptable extraction:
- stale lock patterns;
- sync status UI idea;
- schedule resilience tests;
- logging/observability patterns.

**Do not enable upstream v1 action/handoff classifier as-is.**

Ref:
- `70f799ab3`

Reason:
- OneLink has native tools, runtime control tools, confirmation gates, AI Voice dispatch, RAG lookup semantics.
- A second classifier can conflict with tool execution/handoff decisions.

Acceptable extraction:
- schema ideas;
- deterministic tests/eval cases;
- prompt examples after review.

---

## 8. Voice / WhatsApp Calls Adoption Rules

**Objective:** preserve OneLink/Fonoster/WA media-server architecture and only take upstream edge cases/tests.

### 8.1 Do not adopt wholesale

Do not adopt these upstream changes as direct merge:

- Twilio voice through unified call model.
- Drop/replace `Channel::Voice`.
- Upstream simple WhatsApp Calls controller/service replacing OneLink controller.

Refs:
- `0e122188` — Twilio voice as capability on Twilio SMS.
- `1124c1b4` — Twilio voice flow through unified call model.
- `35308947` — assignment-aware visibility/join conflict.
- `28ec1794` — WhatsApp Cloud Calling provider methods.
- `ea876109` — join active call from conversation bubble.
- `0bd0cab8` — call recordings/duration.
- `de696a55` — WhatsApp inbound call webhook pipeline.
- `58fdd206` — WhatsApp Cloud Calling specs.

Reason:
- OneLink already has:
  - `enterprise/app/controllers/api/v1/accounts/whatsapp_calls_controller.rb` with media-server flow;
  - `agent_answer`, `reconnect`, `join`, `play_audio`, `prepare_outbound`, `dial`;
  - Fonoster `Channel::Voice`;
  - `Telephony::*` models/services;
  - AI Voice runtime.

### 8.2 What to extract

Extract only:
- specs for Meta error `138006` permission request;
- permission-request throttling concept;
- idempotent recording upload guard;
- assignment/join conflict edge cases;
- webhook event parsing cases;
- provider method test fixtures where compatible.

**Verification for any Voice/WA work:**

```bash
ruby -c enterprise/app/controllers/api/v1/accounts/whatsapp_calls_controller.rb
ruby -c enterprise/app/services/whatsapp/call_service.rb
./bin/dev-hybrid rspec spec/enterprise/controllers/api/v1/accounts/whatsapp_calls_controller_spec.rb spec/enterprise/services/whatsapp/incoming_call_service_spec.rb --format progress
pnpm exec eslint app/javascript/dashboard/composables/useCallSession.js app/javascript/dashboard/store/modules/calls.js
pnpm exec vitest --no-watch --no-cache --no-coverage app/javascript/dashboard/composables/specs/useCallSession.spec.js app/javascript/dashboard/store/modules/specs/calls.spec.js
```

---

## 9. Things To Explicitly Avoid

Do not do these:

1. Do not merge upstream `develop` or `v4.14.0` into OneLink directly.
2. Do not apply upstream feature-flag repurpose migrations without OneLink production flag audit:
   - `20260426011444_repurpose_twilio_content_templates_flag_for_captain_document_auto_sync`
   - `20260430114500_repurpose_report_v4_flag_for_captain_v1_action_classifier`
3. Do not drop or replace OneLink `Channel::Voice` / Fonoster stack.
4. Do not replace OneLink WhatsApp Calls controller with upstream simpler controller.
5. Do not downgrade or override OneLink `ruby_llm-schema 0.4.0` with upstream older expectation.
6. Do not introduce OpenAI-only behavior into OneLink provider routing; keep OpenRouter/account-aware policy.
7. Do not stage unrelated current dirty files.
8. Do not update docs submodule pointer unless docs content actually changes and is committed in docs repo first.

---

## 10. Review Checklist Per PR

Before opening/merging each PR:

- [ ] Every upstream commit reference is listed in PR description.
- [ ] OneLink adaptation notes explain what was changed vs upstream and why.
- [ ] No wholesale subsystem replacement.
- [ ] OSS and `enterprise/` paths both checked.
- [ ] Account scoping and authorization verified.
- [ ] Sensitive logs/tokens redacted.
- [ ] Targeted RSpec/Vitest/ESLint run and pasted in PR.
- [ ] `git diff --check` clean.
- [ ] `git status --short --branch --untracked-files=all` reviewed.
- [ ] DB migrations, if any, are safe, reversible where possible, and do not repurpose OneLink flags blindly.
- [ ] Product copy is OneLink/white-label safe.

---

## 11. Suggested Execution Order

1. P0 security branch.
2. P1 backend correctness branch.
3. Dependency bump branch if not included in P1.
4. P2 operator UX branch.
5. P3 integration-specific branches by active integration.
6. P4 CRM Companies epic.
7. Captain/Voice reference tasks only after product owner confirms exact desired behavior.

---

## 12. Final Team Guidance

This work is an **architectural carry**, not a version bump.

Success means:
- OneLink gains the security and product value of Chatwoot 4.14.
- OneLink-specific Captain, Voice, CRM, integrations, and cloud behavior remain coherent.
- The codebase becomes more reliable and easier to operate.
- Every adopted upstream idea has a native OneLink home, tests, and clear rationale.

If a change cannot be explained as “this improves OneLink in its own architecture,” do not carry it yet.
