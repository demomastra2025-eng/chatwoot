# OneLink DEV Platform Improvement Carry Plan

> **For Hermes:** Use `subagent-driven-development` only after the current dirty DEV slice is committed/pushed or moved into a clean integration worktree. Keep every slice path-limited and verified before the next one.

**Goal:** собрать в актуальный DEV не всё подряд, а самое полезное, рабочее и реально улучшающее платформу: runtime/security hardening, native channel health, WhatsApp data correctness, business-document attachments, and low-risk upstream UX/runtime fixes.

**Architecture:** selective carry/adaptation, not wholesale upstream merge. First stabilize current `feature/content-postiz-native-module` DEV work, then add coherent improvement slices with their own tests and commits. OneLink custom Captain/Voice/WhatsApp/CRM code remains source of truth; upstream commits are input, not blind patches.

**Tech Stack:** Rails/Ruby, Enterprise Captain, Vue 3/Vite, Pinia/Vuex legacy surfaces, RSpec, Vitest, ESLint, RuboCop `--fail-level E`.

---

## Current audited baseline

- Repo: `/root/crafty/onelink/chatwoot`
- Current branch: `feature/content-postiz-native-module`
- Current HEAD: `ded142e8e6`
- Upstream sync for branch: `0/0`
- Current main worktree has dirty DEV improvements around Voice/Fonoster, Captain Channels, Inbox BotConfiguration, sidebar/company menu, message layout.

## Non-goals

- Do **not** wholesale merge `v4.14.1` into current dirty branch.
- Do **not** import upstream Voice/WhatsApp Calling wholesale over OneLink Fonoster/media-server work.
- Do **not** drag old Kanban dirty worktrees into this integration unless a specific slice is re-audited.
- Do **not** touch PROD during this plan unless separately approved.

---

## Phase 0 — Stabilize current DEV slice first

**Objective:** make current useful local DEV work a stable base before adding more.

**Files already dirty include:**
- `app/javascript/dashboard/api/channel/voice/*`
- `app/javascript/dashboard/components/widgets/conversation/ReplyBox.vue`
- `app/javascript/dashboard/components/widgets/WootWriter/ReplyBottomPanel.vue`
- `app/javascript/dashboard/routes/dashboard/settings/inbox/Settings.vue`
- `app/javascript/dashboard/routes/dashboard/settings/inbox/components/BotConfiguration.vue`
- `app/javascript/dashboard/routes/dashboard/settings/inbox/components/BotConfiguration.spec.js`
- `app/javascript/dashboard/routes/dashboard/captain/*`
- `app/javascript/dashboard/components-next/sidebar/*`
- `app/javascript/dashboard/components-next/message/*`
- locale JSON files under `app/javascript/dashboard/i18n/locale/*`

**Tasks:**
1. Rebuild exact intended file list for current DEV slice.
2. Ensure untracked `BotConfiguration.spec.js` is included.
3. Run current targeted checks already proven previously:
   - `git diff --check`
   - JSON parse for changed locale files
   - targeted `pnpm exec eslint <changed-js-vue-files>`
   - targeted `pnpm vitest run <changed specs>`
   - `pnpm build:app`
4. Run independent read-only review on this exact slice.
5. Commit/push current DEV slice.
6. Verify local SHA == remote SHA.

**Exit criteria:** current branch clean except intentionally excluded unrelated work; current DEV improvements are committed and pushed.

---

## Phase 1 — Clean Captain runtime hotfix

**Source commit:** `3ba5510072` — `Hotfix Captain runtime preference lookup`

**Function:** Captain runtime state should use direct runtime preferences, not resolve the full `captain_preferences` payload.

**Files:**
- Modify: `enterprise/app/services/captain/assistant/agent_runner_service.rb`
- Modify test: `spec/enterprise/services/captain/assistant/agent_runner_service_spec.rb`

**Implementation:**
1. Cherry-pick/adapt only this commit.
2. Confirm the runtime state uses `account.captain_runtime_preferences`.
3. Add/keep spec that raises if `captain_preferences` is resolved during runtime state build.

**Verification:**
```bash
ruby -c enterprise/app/services/captain/assistant/agent_runner_service.rb
./bin/dev-hybrid rspec spec/enterprise/services/captain/assistant/agent_runner_service_spec.rb --format progress
bundle exec rubocop --fail-level E enterprise/app/services/captain/assistant/agent_runner_service.rb spec/enterprise/services/captain/assistant/agent_runner_service_spec.rb
```

**Exit criteria:** clean commit; no conflict with current frontend DEV slice.

---

## Phase 2 — Runtime/security hardening from `98582dba67`, adapted not copied

**Source commit:** `98582dba67` — `fix: harden 4.14 runtime gaps`

**Reason this is manual:** current DEV already has alternative OneLink implementations for Twilio signature validation, IMAP problematic-email handling, and no-online-agent skip. Missing/uncertain pieces need comparison, not blind cherry-pick.

### Task 2.1 — Dependency/security bump

**Objective:** bring small dependency hardening that is safe and useful.

**Files:**
- `Gemfile`
- `Gemfile.lock`

**Candidates:**
- `jwt` from current `2.10.1` to `2.10.3`
- consider `faraday` only after exact lockfile audit; do not broad-update Rails/RubyLLM stack.

**Verification:**
```bash
bundle update jwt --patch --conservative
bundle exec ruby -e 'require "jwt"; puts JWT::VERSION'
bundle exec rspec spec/controllers/google/callbacks_controller_spec.rb spec/controllers/microsoft/callbacks_controller_spec.rb --format progress
bundle exec rubocop --fail-level E Gemfile
```

### Task 2.2 — AutoAssignment atomic claim

**Objective:** prevent overlapping workers from assigning the same unassigned conversation.

**Files:**
- `app/services/auto_assignment/assignment_service.rb`
- `spec/services/auto_assignment/assignment_service_spec.rb`

**Implementation:**
- Preserve current `available_agents_for_bulk_assignment?` guard.
- Add/adapt atomic claim with row locking / `FOR UPDATE SKIP LOCKED` if compatible with current service.
- Ensure `Current.executed_by` cleanup remains safe.

**Verification:**
```bash
ruby -c app/services/auto_assignment/assignment_service.rb
./bin/dev-hybrid rspec spec/services/auto_assignment/assignment_service_spec.rb --format progress
bundle exec rubocop --fail-level E app/services/auto_assignment/assignment_service.rb spec/services/auto_assignment/assignment_service_spec.rb
```

### Task 2.3 — Twilio webhook signature reconciliation

**Objective:** keep OneLink Twilio webhook validation strict enough without breaking API-key channel compatibility.

**Files:**
- `app/controllers/concerns/twilio_signature_verify_concern.rb`
- `app/controllers/twilio/callback_controller.rb`
- `app/controllers/twilio/delivery_status_controller.rb`
- `spec/controllers/twilio/callbacks_controller_spec.rb`
- `spec/controllers/twilio/delivery_status_controller_spec.rb`

**Implementation:**
- Compare current OneLink concern with `98582dba67`.
- Preserve support for configured account auth token if current OneLink depends on it.
- Add missing negative specs for invalid signature/no channel/no enqueue.
- Keep logs sanitized.

**Verification:**
```bash
ruby -c app/controllers/concerns/twilio_signature_verify_concern.rb
./bin/dev-hybrid rspec spec/controllers/twilio/callbacks_controller_spec.rb spec/controllers/twilio/delivery_status_controller_spec.rb --format progress
bundle exec rubocop --fail-level E app/controllers/concerns/twilio_signature_verify_concern.rb app/controllers/twilio/callback_controller.rb app/controllers/twilio/delivery_status_controller.rb spec/controllers/twilio/callbacks_controller_spec.rb spec/controllers/twilio/delivery_status_controller_spec.rb
```

### Task 2.4 — IMAP problematic-email reconciliation

**Objective:** ensure one bad IMAP email cannot wedge polling and timeout configuration is documented.

**Files:**
- `.env.example`
- `app/jobs/inboxes/fetch_imap_emails_job.rb`
- `spec/jobs/inboxes/fetch_imap_emails_job_spec.rb`

**Implementation:**
- Current OneLink already has `EMAIL_PROCESSING_TIMEOUT_SECONDS`, Redis hashed problematic-email keys, threshold and TTL.
- Add missing `.env.example` docs if absent/broken.
- Add/adjust specs for timeout, skip after threshold, continue next email, safe identifier/fingerprint.

**Verification:**
```bash
ruby -c app/jobs/inboxes/fetch_imap_emails_job.rb
./bin/dev-hybrid rspec spec/jobs/inboxes/fetch_imap_emails_job_spec.rb --format progress
bundle exec rubocop --fail-level E app/jobs/inboxes/fetch_imap_emails_job.rb spec/jobs/inboxes/fetch_imap_emails_job_spec.rb
```

**Phase 2 exit criteria:** runtime/security hardening is present as OneLink-native code, not a conflicted upstream copy.

---

## Phase 3 — Native inbox reauthorization / channel health UI

**Source commit:** `2f98edc1a8` — `[verified] Add native inbox reauthorization status updates`

**Function:** show and broadcast native inbox health when channels need reauthorization or recover, with sanitized details.

**Files:**
- `app/models/concerns/reauthorizable.rb`
- `app/models/inbox.rb`
- `app/presenters/inbox/event_data_presenter.rb`
- `spec/models/concerns/reauthorizable_shared.rb`
- `app/javascript/dashboard/routes/dashboard/settings/inbox/Settings.vue`
- Create: `app/javascript/dashboard/routes/dashboard/settings/inbox/helpers/inboxHealthStatus.js`
- Create: `app/javascript/dashboard/routes/dashboard/settings/inbox/helpers/inboxHealthStatus.spec.js`
- locale files: `app/javascript/dashboard/i18n/locale/{en,ru,kk}/inboxMgmt.json`

**Implementation notes:**
- Emit `inbox_updated` only on real reauthorization state transitions.
- Do not assume every `Reauthorizable` object has an inbox.
- Redact provider/runtime error details: tokens, keys, secrets, passwords.
- Merge carefully with current `Settings.vue` dirty/committed BotConfiguration changes.

**Verification:**
```bash
ruby -c app/models/concerns/reauthorizable.rb app/models/inbox.rb app/presenters/inbox/event_data_presenter.rb
./bin/dev-hybrid rspec spec/models/concerns/reauthorizable_shared.rb --format progress
pnpm vitest run app/javascript/dashboard/routes/dashboard/settings/inbox/helpers/inboxHealthStatus.spec.js
pnpm exec eslint app/javascript/dashboard/routes/dashboard/settings/inbox/Settings.vue app/javascript/dashboard/routes/dashboard/settings/inbox/helpers/inboxHealthStatus.js
python3 -m json.tool app/javascript/dashboard/i18n/locale/en/inboxMgmt.json >/dev/null
python3 -m json.tool app/javascript/dashboard/i18n/locale/ru/inboxMgmt.json >/dev/null
python3 -m json.tool app/javascript/dashboard/i18n/locale/kk/inboxMgmt.json >/dev/null
```

---

## Phase 4 — WhatsApp BSUID + unavailable message correctness

**Source commit:** `679ae1514a` — `fix: support whatsapp bsuid identifiers`

**Function:** prevent duplicate/ghost WhatsApp contacts and preserve unsupported/coexistence messages.

**Files:**
- Create: `app/services/contact_inbox_source_id_resolver.rb`
- Create: `app/services/whatsapp/identifier_sync_service.rb`
- Create: `app/services/whatsapp/incoming_message_identifier_helper.rb`
- Modify: `app/services/whatsapp/incoming_message_base_service.rb`
- Modify: `app/services/whatsapp/incoming_message_service_helpers.rb`
- Modify: `lib/regex_helper.rb`
- Modify specs under `spec/services/whatsapp/*` and `spec/models/contact_inbox_spec.rb`
- Modify unsupported message UI:
  - `app/javascript/dashboard/components-next/message/bubbles/Unsupported.vue`
  - `app/javascript/dashboard/components-next/message/bubbles/Unsupported.spec.js`
  - `app/javascript/dashboard/components-next/message/Message.spec.js`
  - locale `conversation.json` and Rails locales.

**Implementation notes:**
- Link phone source id and BSUID source id to the same contact when both appear.
- Backfill phone/username without overwriting safer existing values.
- Store unsupported WhatsApp messages as placeholder messages instead of headless conversations.
- Keep OneLink WhatsApp Web / WhatsApp Cloud divergence in mind.

**Verification:**
```bash
ruby -c app/services/contact_inbox_source_id_resolver.rb app/services/whatsapp/identifier_sync_service.rb app/services/whatsapp/incoming_message_identifier_helper.rb app/services/whatsapp/incoming_message_base_service.rb app/services/whatsapp/incoming_message_service_helpers.rb lib/regex_helper.rb
./bin/dev-hybrid rspec spec/models/contact_inbox_spec.rb spec/services/whatsapp/incoming_message_service_spec.rb spec/services/whatsapp/incoming_message_whatsapp_cloud_service_spec.rb --format progress
pnpm vitest run app/javascript/dashboard/components-next/message/bubbles/Unsupported.spec.js app/javascript/dashboard/components-next/message/Message.spec.js
pnpm exec eslint app/javascript/dashboard/components-next/message/bubbles/Unsupported.vue app/javascript/dashboard/components-next/message/Message.spec.js
```

---

## Phase 5 — XML/PFX/P12 business-document attachments

**Source commit:** `63481e7be8` — `fix: support xml and certificate attachments`

**Function:** support customer business documents and certificate bundles safely.

**Files:**
- `app/javascript/shared/constants/messages.js`
- `app/javascript/shared/helpers/FileHelper.js`
- `app/javascript/shared/helpers/specs/FileHelper.spec.js`
- `app/javascript/dashboard/components-next/icon/FileIcon.vue`
- Create: `app/javascript/dashboard/components-next/icon/FileIcon.spec.js`
- `app/javascript/dashboard/components-next/message/chips/File.vue`
- `app/javascript/dashboard/components/widgets/WootWriter/ReplyBottomPanel.vue`
- `app/models/attachment.rb`
- `config/initializers/active_storage.rb`
- `spec/models/attachment_spec.rb`

**Implementation notes:**
- Allow `.xml`, `.pfx`, `.p12` only where document-capable channels allow documents.
- Certificate files must be download-only, not inline browser-rendered.
- Do not loosen restricted WhatsApp channels.
- Merge carefully with current ReplyBottomPanel voice/composer changes.

**Verification:**
```bash
ruby -c app/models/attachment.rb config/initializers/active_storage.rb
./bin/dev-hybrid rspec spec/models/attachment_spec.rb --format progress
pnpm vitest run app/javascript/shared/helpers/specs/FileHelper.spec.js app/javascript/dashboard/components-next/icon/FileIcon.spec.js
pnpm exec eslint app/javascript/shared/helpers/FileHelper.js app/javascript/shared/constants/messages.js app/javascript/dashboard/components-next/icon/FileIcon.vue app/javascript/dashboard/components-next/message/chips/File.vue app/javascript/dashboard/components/widgets/WootWriter/ReplyBottomPanel.vue
```

---

## Phase 6 — Low-risk upstream `v4.14.1` improvements to selectively carry

**Objective:** add useful clean or low-risk platform improvements without a full release merge.

### Recommended P1/P2 candidates

1. `03fb6591e0` — relax conversation meta polling for high-volume accounts
   - File: `app/javascript/dashboard/store/modules/conversationStats.js`
   - Benefit: less frontend/API pressure on large accounts.

2. `2628d7a7fd` — prevent Alt shortcuts while typing
   - Files: `WootWriter/Editor.vue`, `ReplyTopPanel.vue`, keyboard events spec
   - Benefit: fewer accidental shortcuts while composing.

3. `6c8741b314` — increase audit log page size
   - Files: audit log controller/store/swagger/spec
   - Benefit: better operator visibility.

4. `3b7b94f8d1` — prevent code block overflow in message bubble
   - Files: `Message.vue`, `Base.vue`
   - Benefit: message layout hardening. Check if current local message-width work already covers this.

5. `39a93db007` + `7422b656cd` — sidebar status no-wrap/overflow fixes
   - File: `SidebarProfileMenuStatus.vue`
   - Benefit: small UI polish; second commit conflicts, adapt manually.

6. `94daf26ead` — dependency update jwt/faraday
   - Benefit: security/dependency hygiene.
   - Must be lockfile-audited; avoid broad stack drift.

### Candidates to defer unless current business need exists

- `7c16071fc7` SafeFetch private API inbox webhooks: useful only if customers need internal webhook URLs; keep fail-closed by default.
- `37c8e7e699` Firecrawl long external link migration: useful for Captain docs, but conflicts with OneLink RAG/Firecrawl flow.
- `d20950c5b4` scheduler fairness: useful but touches Captain docs scheduling; separate Captain runtime slice.
- `68e358d732` voice-call UX fixes: use only as reference because OneLink Voice/Fonoster is customized.
- Bulk labels/help center/onboarding/TikTok: product P2/P3, not core platform hardening.

---

## Final verification matrix

Run after each phase, with only touched paths where possible:

```bash
git diff --check
# Ruby
ruby -c <changed-ruby-files>
bundle exec rubocop --fail-level E <changed-ruby-and-spec-files>
./bin/dev-hybrid rspec <targeted-specs> --format progress
# Frontend
pnpm exec eslint <changed-js-vue-files>
pnpm vitest run <targeted-vitest-specs>
# Data files
python3 -m json.tool <changed-json-files> >/dev/null
ruby -e 'require "yaml"; ARGV.each { |f| YAML.load_file(f) }' <changed-yml-files>
```

Before final push:
1. `git status --short --branch --untracked-files=all`
2. `git diff --check`
3. secret/static scan over added lines
4. independent read-only review of the exact staged diff
5. commit each phase separately
6. push branch
7. verify local SHA == remote SHA
8. restart only DEV service if approved/needed
9. smoke `dev.one-link.kz` key paths if DEV was restarted

## Delivery order summary

1. Commit/push current DEV dirty slice.
2. Add clean Captain hotfix `3ba5510072`.
3. Runtime/security hardening reconciliation from `98582dba67`.
4. Native inbox reauthorization health UI/events.
5. WhatsApp BSUID/contact correctness.
6. XML/PFX/P12 business attachments.
7. Selective `v4.14.1` low-risk improvements.
8. Optional/deferred product epics only after separate approval.
