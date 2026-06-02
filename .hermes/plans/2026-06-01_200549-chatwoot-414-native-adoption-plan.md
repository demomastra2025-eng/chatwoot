# OneLink Chatwoot 4.14.0/4.14.1 Native Adoption Plan

> **For Hermes:** Use subagent-driven-development skill to implement this plan task-by-task. Keep every slice path-limited, reviewed, tested, and safe for OneLink custom runtime.

**Goal:** Дотянуть из upstream Chatwoot 4.14.0/4.14.1 только разумные для OneLink backend/frontend/interface изменения так, чтобы они были нативными, надёжными, системными, качественными и соответствовали реальным кейсам проекта.

**Architecture:** Не делать wholesale merge. Каждый upstream item переносить как OneLink-native slice: сначала доказать текущий gap в OneLink, затем адаптировать под существующие модели/feature flags/интеграции/Captain/Voice, добавить targeted specs и только после этого включать UI/API поведение. Runtime correctness и безопасность идут раньше UX/косметики.

**Tech Stack:** Rails, Enterprise overlays, Sidekiq/ActiveJob, Redis, PostgreSQL, Vue 3, Pinia/Vuex legacy stores, Vite, Vitest, RSpec, RuboCop, ESLint, Chatwoot upstream tags `v4.14.0`/`v4.14.1`, OneLink fork `/root/crafty/onelink/chatwoot`.

---

## 0. Принципы переноса

### Что считаем нативным для OneLink

- Используем существующие Rails models/services/controllers/jobs, а не параллельные sidecar-слои.
- Для Enterprise/Captain/Voice учитываем OneLink overlays в `enterprise/` до изменения shared-кода.
- Для UI используем существующие settings/sidebar/design-system паттерны, без внедрения чужих layout-решений поверх OneLink IA.
- Для интеграций сохраняем текущие OneLink правила безопасности: fail-closed, account-scoped, no secret leakage, explicit allowlist для опасных сценариев.
- Для API сохраняем backward compatibility, если клиентские интеграции могли зависеть от текущего поведения.

### Чего НЕ делаем

- Не тянем весь upstream 4.14.1 одним merge.
- Не переносим wholesale upstream WhatsApp Cloud Calling UI в OneLink Voice/Fonoster/media-server стек.
- Не ломаем OneLink working hours/touch/follow-up поведение без отдельного RCA/плана.
- Не меняем PROD/restart/deploy без явного разрешения.
- Не смешиваем эти изменения с текущими dirty-файлами Captain/backend/sidebar, если они не входят в slice.

### Общий acceptance gate для каждого slice

- Текущий gap доказан кодом/тестом.
- Есть минимальный backend или frontend regression test.
- Есть targeted lint/spec/vitest.
- Есть `git diff --check`.
- Есть independent review перед commit.
- Есть DEV smoke только для реально затронутого UI/API.
- В отчёте явно указано: PROD touched/not touched.

---

## 1. Текущий baseline из аудита

### Уже считается покрытым / не первоочередное

- SafeFetch/SSRF hardening для webhook/macros/automation/avatar в базовом виде.
- WhatsApp/Instagram Meta HMAC validation.
- Swagger path traversal guard.
- ActiveStorage direct upload metadata/range hardening.
- Custom attributes admin auth.
- SAML flow.
- Большая часть dependency-базы 4.14.x: `rack`, `rack-session`, `nokogiri`, `net-imap`, `dompurify`, `video.js`.
- Shared attachments в conversation sidebar.
- Rich WhatsApp/Twilio template preview.
- Platform status banners.
- Super-admin push diagnostics.
- Companies/Organizations поверхности.

### Нужны selective carry/adaptation

- Twilio webhook signature validation.
- IMAP timeout + skip problematic emails.
- Auto-assignment atomic claim/no-online-agent loop guard.
- `jwt` и `sidekiq-cron` dependency delta.
- Captain document `external_link`/`text` semantics.
- `inbox_updated` event on disconnect/reauthorization.
- SafeFetch private-network allowlist for API inbox webhooks, только если нужен controlled internal webhook use case.
- Unread counts UX/API/store/sidebar, отдельным продуктовым slice.
- WhatsApp BSUID/coexistence unavailable messages, только data/edge-case adaptation.
- XML/PFX attachments.
- Help Center bulk/translation/layout/markdown route, отдельным Help Center slice.
- OpenAI hook validator / Whisper guard, только если legacy OpenAI/transcription paths активны.

---

## 2. Phase A — P0 security/runtime correctness

### Task A1: Twilio webhook signature validation

**Objective:** Закрыть публичные Twilio callback endpoints от forged webhook payloads.

**Project case:** Если OneLink использует Twilio SMS/WhatsApp/Delivery callbacks, любой публичный endpoint без `X-Twilio-Signature` может принимать неподписанные события.

**Files likely to change:**

- Create: `app/controllers/concerns/twilio_signature_verify_concern.rb`
- Modify: `app/controllers/twilio/callback_controller.rb`
- Modify: `app/controllers/twilio/delivery_status_controller.rb`
- Test: `spec/controllers/twilio/callbacks_controller_spec.rb`
- Test: `spec/controllers/twilio/delivery_status_controller_spec.rb`
- Possibly inspect: `app/jobs/webhooks/twilio_events_job.rb`
- Possibly inspect: `app/jobs/webhooks/twilio_delivery_status_job.rb`

**Implementation notes:**

1. Do not copy blindly if OneLink route URL/proxy headers differ.
2. Build validation from Twilio auth token already stored for the relevant channel/account.
3. Fail closed when channel/auth token can be resolved and signature is invalid.
4. For legacy channels without enough config, choose one explicit policy:
   - hard-fail if production security requires it;
   - or log warning + allow only behind a transitional feature flag.
5. Never log auth token/signature raw values.

**Backend tests:**

- Valid signature enqueues job.
- Invalid signature returns unauthorized and does not enqueue job.
- Missing signature returns unauthorized for configured Twilio channel.
- Delivery status endpoint has the same coverage.

**Verification commands:**

```bash
bundle exec rspec spec/controllers/twilio/callbacks_controller_spec.rb spec/controllers/twilio/delivery_status_controller_spec.rb
bundle exec ruby -c app/controllers/concerns/twilio_signature_verify_concern.rb
bundle exec rubocop app/controllers/concerns/twilio_signature_verify_concern.rb app/controllers/twilio/callback_controller.rb app/controllers/twilio/delivery_status_controller.rb --fail-level E
git diff --check
```

**Acceptance:** forged Twilio webhook cannot mutate conversations/messages/statuses.

---

### Task A2: IMAP timeout and problematic email skip

**Objective:** Одно битое/тяжёлое письмо не должно стопорить polling всего email inbox.

**Project case:** Email inboxes в проде могут получать большие/битые MIME письма; без timeout процессор может зависать, повторять один и тот же failure и задерживать всю очередь.

**Files likely to change:**

- Modify: `app/jobs/inboxes/fetch_imap_emails_job.rb`
- Inspect/possibly modify: `app/services/imap/base_fetch_email_service.rb`
- Test: `spec/jobs/inboxes/fetch_imap_emails_job_spec.rb`
- Possibly env docs: `.env.example` for `EMAIL_PROCESSING_TIMEOUT_SECONDS`

**Implementation notes:**

1. Add per-email `Timeout.timeout(email_processing_timeout)` around mailbox processing.
2. Track failures by stable `message_id` in Rails cache/Redis with TTL.
3. Skip message after threshold, log `[IMAP] Skipping problematic email`.
4. Preserve OAuth authorization error handling.
5. Preserve OneLink IMAP auth/settings behavior if already customized.

**Backend tests:**

- Timeout increments failure count and continues processing next email.
- Repeated failures skip the problematic message.
- OAuth authorization still marks channel authorization error.
- Normal email still processes and does not mark failure.

**Verification commands:**

```bash
bundle exec rspec spec/jobs/inboxes/fetch_imap_emails_job_spec.rb
bundle exec ruby -c app/jobs/inboxes/fetch_imap_emails_job.rb
git diff --check
```

**Acceptance:** bad email cannot wedge the inbox queue.

---

### Task A3: AutoAssignment atomic claim and no-online-agent guard

**Objective:** Исключить duplicate assignment races и лишние циклы при отсутствии online agents.

**Project case:** В high-load inbox/teams несколько workers могут пытаться назначить один conversation одновременно; при no agents online bulk loop должен останавливаться без лишней нагрузки.

**Files likely to change:**

- Modify: `app/services/auto_assignment/assignment_service.rb`
- Possibly inspect: `app/services/auto_assignment/*`
- Test: `spec/services/auto_assignment/assignment_service_spec.rb`
- Possibly test: team/inbox assignment specs if present.

**Implementation notes:**

1. Use atomic DB claim pattern scoped by conversation state/assignee.
2. Do not override already assigned conversation.
3. Guard early when no online agents are eligible.
4. Preserve OneLink custom assignment policies if present.
5. Add instrumentation/logs only if consistent with existing logging.

**Backend tests:**

- Two assignment attempts cannot assign same conversation to different agents.
- Existing assignee is preserved.
- No online agents returns cleanly without looping.
- Team/inbox eligibility rules still apply.

**Verification commands:**

```bash
bundle exec rspec spec/services/auto_assignment/assignment_service_spec.rb
bundle exec ruby -c app/services/auto_assignment/assignment_service.rb
git diff --check
```

**Acceptance:** assignment is race-safe and load-safe.

---

### Task A4: Dependency hardening delta — `jwt`, `sidekiq-cron`

**Objective:** Закрыть security/runtime delta без случайного dependency drift.

**Project case:** `jwt` в OneLink ниже upstream 4.14.1; `sidekiq-cron` сильно ниже и влияет на scheduled jobs.

**Files likely to change:**

- Modify: `Gemfile.lock`
- Possibly modify: `Gemfile` only if constraint blocks update.
- Test/verify scheduled jobs configs under `config/`, `lib/tasks/`, `app/jobs/`.

**Implementation notes:**

1. First run dependency impact audit in temp lockfile, not dirtying repo.
2. Update only intended gems.
3. Confirm Rails/ActiveRecord/RubyLLM/etc did not drift unless explicitly scoped.
4. For `sidekiq-cron`, inspect scheduler initialization and cron syntax compatibility.
5. If `sidekiq-cron` 2.4.0 is too risky, split `jwt` first and make `sidekiq-cron` separate runtime-tested slice.

**Verification commands:**

```bash
bundle update jwt --patch --conservative
bundle update sidekiq-cron --minor --conservative
bundle exec ruby -e "require 'jwt'; require 'sidekiq/cron/job'; puts 'deps-ok'"
bundle exec rspec spec/jobs spec/lib --fail-fast
bundle exec bundle-audit check --update
git diff -- Gemfile Gemfile.lock
git diff --check
```

**Acceptance:** dependency delta closed with no accidental stack upgrade.

---

## 3. Phase B — Integration correctness and API events

### Task B1: Emit `inbox_updated` when inbox disconnects / reauthorization required

**Objective:** External integrations and operators should know when an inbox becomes disconnected/reauthorization-required.

**Project case:** WhatsApp/Instagram/TikTok/Email disconnects should be visible via webhook/account event and UI cache invalidation, not only hidden Redis state.

**Files likely to change:**

- Modify: `app/models/concerns/reauthorizable.rb`
- Modify/inspect: `app/models/inbox.rb`
- Modify/inspect: `app/listeners/webhook_listener.rb`
- Modify/inspect: `app/presenters/inbox/event_data_presenter.rb`
- Test: `spec/listeners/webhook_listener_spec.rb`
- Test: `spec/models/concerns/reauthorizable_spec.rb` or model-specific spec.

**Implementation notes:**

1. Dispatch `INBOX_UPDATED` only when state changes to reauthorization-required/disconnected.
2. Include safe `changed_attributes`/status payload; do not leak tokens/provider config secrets.
3. Preserve existing `update_account_cache` behavior.
4. Ensure repeated errors do not spam duplicate webhook events after state already set.

**Backend tests:**

- `authorization_error!` crossing threshold emits `inbox_updated` once.
- Payload includes inbox identity/status but no secrets.
- `reauthorized!` updates cache and can emit/update if product expects it.

**Verification commands:**

```bash
bundle exec rspec spec/listeners/webhook_listener_spec.rb
bundle exec ruby -c app/models/concerns/reauthorizable.rb app/listeners/webhook_listener.rb
git diff --check
```

**Acceptance:** disconnect state is observable by account webhooks/UI caches.

---

### Task B2: SafeFetch private-network allowlist for API inbox webhooks

**Objective:** Разрешить internal/private webhook URLs только явно и безопасно, не ослабляя SSRF защиту по умолчанию.

**Project case:** Некоторым enterprise/self-hosted клиентам могут быть нужны internal webhook endpoints; OneLink cloud default должен оставаться fail-closed.

**Files likely to change:**

- Modify: `lib/safe_fetch.rb`
- Modify: `lib/safe_fetch/fetcher.rb`
- Modify: `lib/safe_fetch/request_options.rb`
- Create/modify: `lib/safe_fetch/private_network_request.rb`
- Modify/inspect: `app/models/channel/api.rb`
- Modify/inspect: `lib/webhooks/trigger.rb`
- Test: `spec/lib/safe_fetch_spec.rb`
- Test: `spec/lib/webhooks/trigger_spec.rb`

**Implementation notes:**

1. Default stays private-network denied.
2. Allow private network only for API inbox webhook with explicit allowlist/env/account setting.
3. Validate redirects too: public URL redirecting to private IP must be denied unless explicitly allowed.
4. Do not allow metadata IPs/link-local unless explicitly impossible by policy.
5. Include request reason/context in logs without secrets.

**Backend tests:**

- Public URL allowed.
- Private IP denied by default.
- Redirect to private IP denied.
- Allowlisted private URL allowed only in configured API inbox webhook context.
- Sensitive auth headers stripped across cross-origin redirects.

**Verification commands:**

```bash
bundle exec rspec spec/lib/safe_fetch_spec.rb spec/lib/webhooks/trigger_spec.rb
bundle exec ruby -c lib/safe_fetch.rb lib/safe_fetch/fetcher.rb lib/safe_fetch/request_options.rb
git diff --check
```

**Acceptance:** internal webhook support is explicit, test-covered, and cannot become a general SSRF bypass.

---

### Task B3: WhatsApp BSUID and coexistence unavailable messages

**Objective:** Дотянуть data/edge-case handling для WhatsApp coexistence без переноса upstream calling stack.

**Project case:** Клиенты могут отвечать из WhatsApp Business app; OneLink должен корректно связывать identifiers и явно показывать unsupported/unavailable messages.

**Files likely to change:**

- Modify/inspect: `app/jobs/webhooks/whatsapp_events_job.rb`
- Modify/inspect: `app/services/whatsapp/incoming_message_whatsapp_cloud_service.rb`
- Modify/inspect: `app/models/contact_inbox.rb`
- Modify/inspect: `app/presenters/message_presenter.rb` / serializers if present.
- Frontend inspect: message bubble components under `app/javascript/dashboard/components-next/message/`
- Tests: WhatsApp webhook/incoming service specs.

**Implementation notes:**

1. Backport BSUID/source identifier logic only if not already covered by OneLink gateway/channel identifiers.
2. Preserve OneLink WhatsApp Web/Cloud/custom gateway behavior.
3. Store unavailable coexistence payload in safe message/additional attributes shape.
4. UI should show clear system/unsupported message, not blank bubble.

**Backend tests:**

- Inbound webhook with BSUID stores/resolves contact identity correctly.
- Unavailable coexistence message creates visible safe message.
- Existing phone_number_id validation still works.

**Frontend tests:**

- Message with unavailable/unsupported metadata renders informative text.
- No JS error when unsupported metadata is missing/partial.

**Verification commands:**

```bash
bundle exec rspec spec/jobs/webhooks/whatsapp_events_job_spec.rb spec/services/whatsapp/incoming_message_whatsapp_cloud_service_spec.rb
pnpm exec vitest run app/javascript/dashboard/components-next/message --run
git diff --check
```

**Acceptance:** WhatsApp coexistence edge cases are visible and identity-safe.

---

## 4. Phase C — Frontend/interface product UX

### Task C1: Unread counts — API/store/sidebar native slice

**Objective:** Добавить нативные unread count badges/order для conversations/labels/teams/channels только после backend events/cache readiness.

**Project case:** Для операторов и менеджеров важна приоритизация inbox/team/label по непрочитанным; но OneLink sidebar уже кастомизирован, поэтому нужен осторожный перенос.

**Backend files likely to change:**

- Create/modify: `app/services/conversations/unread_count*` or equivalent builder.
- Modify: `app/controllers/api/v1/accounts/conversations_controller.rb` or new endpoint.
- Modify: `config/routes.rb`
- Modify: event invalidation in conversation/message/notification flows.
- Migration/feature flag if needed.
- Tests: controller/service specs.

**Frontend files likely to change:**

- Modify: `app/javascript/dashboard/api/conversations.js` or dedicated unread API client.
- Modify: conversation store module / Pinia store for unread counts.
- Modify: `app/javascript/dashboard/components-next/sidebar/Sidebar.vue`
- Modify: sidebar group/item components if badge rendering is centralized.
- Modify: `app/javascript/dashboard/components-next/sidebar/sidebarVisibility.js` only if new visibility keys are needed.
- Test: `app/javascript/dashboard/components-next/sidebar/sidebarVisibility.spec.js`
- Test: store/API specs if existing.

**Interface requirements:**

- Badges subtle, consistent with current OneLink sidebar design.
- Counts should not visually overpower navigation.
- Zero counts hidden.
- Loading state should not flicker/reorder aggressively.
- Respect permissions and sidebar visibility settings.
- Ordering by unread count must not break manual/group ordering expectations.

**Implementation notes:**

1. Start with backend endpoint/service + tests.
2. Add frontend store refresher with bounded polling/event-driven refresh.
3. Add badges to sidebar item component, not repeated ad-hoc markup.
4. Add feature flag if migration/behavior risk is high.
5. Avoid conflicting with recent OneLink IA changes: `Моя компания`/`Организации`, Captain logs/testing labels, labels/tagged-with action buttons.

**Verification commands:**

```bash
bundle exec rspec spec/services/conversations spec/controllers/api/v1/accounts/conversations_controller_spec.rb
pnpm exec vitest run app/javascript/dashboard/components-next/sidebar/sidebarVisibility.spec.js
pnpm exec eslint app/javascript/dashboard/components-next/sidebar app/javascript/dashboard/api app/javascript/dashboard/store --max-warnings=0
pnpm build:app
git diff --check
```

**Acceptance:** unread counts improve navigation without IA/sidebar regression.

---

### Task C2: XML/PFX attachment support

**Objective:** Поддержать реальные бизнес-вложения: XML invoices/acts и PFX/cert files, безопасно и понятно в UI.

**Project case:** Казахстанские/enterprise клиенты часто обмениваются XML/сертификатами/документами; OneLink должен принять файл, показать его, дать скачать, но не исполнять опасный контент inline.

**Backend files likely to change:**

- Modify: `app/models/attachment.rb`
- Modify/inspect: attachment/content-type validation concerns.
- Modify/inspect: ActiveStorage content type inline/download policies.
- Test: `spec/models/attachment_spec.rb`

**Frontend files likely to change:**

- Modify/inspect: attachment upload/dropzone components.
- Modify/inspect: attachment preview/download components.
- Locale strings if new labels/errors are needed.
- Test: component specs/vitest if present.

**Interface requirements:**

- XML can be attached and downloaded; preview only if existing safe text-preview policy supports it.
- PFX should be download-only, never inline-rendered.
- Error message should be explicit if file type is blocked.
- File icon/type label should not look broken.

**Verification commands:**

```bash
bundle exec rspec spec/models/attachment_spec.rb
pnpm exec eslint app/javascript/dashboard/components --max-warnings=0
pnpm build:app
git diff --check
```

**Acceptance:** XML/PFX business files work without weakening browser/file safety.

---

### Task C3: Help Center enhancements as separate product slice

**Objective:** Дотянуть только те Help Center функции, которые реально нужны OneLink customers/support.

**Project case:** Если OneLink использует Help Center как customer self-service, полезны bulk actions, translation, layout switch, markdown routes. Если нет — не тратить релизный риск сейчас.

**Backend files likely to change if accepted:**

- Controllers under `app/controllers/api/v1/accounts/articles*`
- Models/services for article translation/bulk actions.
- Routes in `config/routes.rb`
- Jobs for translation/generation if enabled.
- Specs under `spec/controllers/api/v1/accounts/articles*`, `spec/services/*article*`.

**Frontend files likely to change if accepted:**

- Help Center article list bulk action UI.
- Article translation UI/action menus.
- Portal layout switch settings UI.
- Public portal routes/components for `.md` route if adopted.
- Locales: EN/RU/KK.

**Decision checklist before implementation:**

- Is Help Center actively used by OneLink customers today?
- Which languages are required: RU/KK/EN?
- Should AI translation use OpenRouter account-aware runtime or legacy OpenAI hook?
- Is public `.md` route needed for SEO/integrations?
- Does layout switch conflict with OneLink branding?

**Verification commands:**

```bash
bundle exec rspec spec/controllers/api/v1/accounts/articles spec/services | grep -E 'article|portal|help' || true
pnpm exec vitest run app/javascript/dashboard/routes/dashboard/helpcenter --run
pnpm build:app
git diff --check
```

**Acceptance:** Help Center changes ship as coherent user-facing feature, not incidental upstream residue.

---

### Task C4: Interface polish for integration health/status

**Objective:** Сделать disconnect/unavailable/error states видимыми и логичными в интерфейсе после backend correctness fixes.

**Project case:** Админ должен видеть, что inbox/integration отключён, почему, и что делать дальше; оператор не должен видеть silent failures.

**Frontend files likely to inspect/change:**

- Settings inbox pages under `app/javascript/dashboard/routes/dashboard/settings/inbox*`
- Integration settings under `app/javascript/dashboard/routes/dashboard/settings/integrations/`
- Sidebar/channel badges if disconnect should surface there.
- Store/composables for account/inbox config.
- Locales: `app/javascript/dashboard/i18n/locale/{en,ru,kk}/*.json`

**Interface requirements:**

- Clear status: connected / needs reauthorization / webhook signature invalid / provider unavailable.
- No raw provider secrets, tokens, or signatures.
- One primary action per state: reconnect, retry, open settings, copy webhook URL, etc.
- Use existing OneLink design primitives, not new random cards.
- RU/KK/EN locales complete.

**Frontend tests:**

- Status component renders correct state from inbox payload.
- Missing/partial payload does not crash.
- Locale keys exist in EN/RU/KK.

**Verification commands:**

```bash
python -m json.tool app/javascript/dashboard/i18n/locale/en/settings.json >/dev/null
python -m json.tool app/javascript/dashboard/i18n/locale/ru/settings.json >/dev/null
python -m json.tool app/javascript/dashboard/i18n/locale/kk/settings.json >/dev/null
pnpm exec eslint app/javascript/dashboard/routes/dashboard/settings --max-warnings=0
pnpm build:app
git diff --check
```

**Acceptance:** backend health states are actionable in UI.

---

## 5. Phase D — Captain/AI-specific adaptation

### Task D1: Captain document `external_link`/`text` semantics

**Objective:** Align upstream Captain document semantics only if compatible with OneLink custom RAG/document chunks/retrieval traces.

**Project case:** OneLink Captain relies on semantic/vector search, assistant responses, retrieval traces, and custom tool safety. A blind migration can break indexed knowledge.

**Files likely to inspect/change:**

- Migration: `db/migrate/*change_captain_document_external_link_to_text.rb` if adopted.
- Enterprise jobs: `enterprise/app/jobs/captain/documents/*`
- Enterprise services: `enterprise/app/services/captain/documents/*`
- Retrieval services/tools: `enterprise/app/services/captain/tools/*documentation*`, `faq_lookup*`
- Models: Captain document/chunk models under `enterprise/app/models/`.
- Specs: Captain document indexing/search/crawl specs.

**Implementation notes:**

1. First map current OneLink schema and document lifecycle.
2. Dry-run migration on DEV/test data only.
3. Ensure existing indexed chunks remain recoverable or are reindexed.
4. Preserve answer-cache/vector-search semantics.
5. Add rollback plan if migration is destructive.

**Backend tests:**

- Existing URL document still crawls/indexes after migration.
- Uploaded/file document still indexes.
- FAQ/documentation search still returns semantic results.
- Failure path reports degraded state, not lexical-only fallback pretending success.

**Verification commands:**

```bash
bundle exec rspec spec/enterprise/services/captain spec/enterprise/jobs/captain spec/enterprise/lib/captain --fail-fast
RAILS_ENV=test bundle exec rails db:migrate:status
bundle exec ruby -c enterprise/app/jobs/captain/documents/*.rb
git diff --check
```

**Acceptance:** Captain knowledge stays semantically correct after schema/field adaptation.

---

### Task D2: OpenAI hook validator / audio transcription guard decision

**Objective:** Decide whether upstream OpenAI/Whisper fixes apply to OneLink or are superseded by OpenRouter/account-aware runtime.

**Project case:** OneLink should not add legacy OpenAI-only UI if runtime is OpenRouter/account-scoped; but if old OpenAI hooks remain enabled, invalid credentials must be visible and safe.

**Files likely to inspect/change if needed:**

- `app/models/integrations/hook.rb`
- `lib/integrations/openai/key_validator.rb` if adopted.
- `app/jobs/migration/validate_openai_hooks_job.rb` if adopted.
- `enterprise/app/services/messages/audio_transcription_service.rb`
- Integration settings UI and locales.

**Decision checklist:**

- Are any accounts still using legacy OpenAI integration hooks?
- Does Captain/audio transcription use OpenRouter runtime only?
- Is there already account-aware key validation for OpenRouter/OpenAI providers?
- Is Whisper 25MB guard still relevant after OneLink audio normalization?

**Verification commands:**

```bash
bundle exec rspec spec/lib/integrations spec/enterprise/services/messages/audio_transcription_service_spec.rb
bundle exec ruby -c enterprise/app/services/messages/audio_transcription_service.rb
git diff --check
```

**Acceptance:** AI provider credential/audio behavior is safe without duplicating legacy architecture.

---

## 6. Recommended implementation order

### Release slice 1 — security/runtime hotfix-quality

1. A1 Twilio signature validation.
2. A2 IMAP timeout/skip.
3. A3 AutoAssignment atomic claim/no-online-agent guard.
4. A4 `jwt` update; decide whether `sidekiq-cron` goes with it or separate.

**Why first:** direct security/runtime correctness, lowest UI coupling.

### Release slice 2 — integration observability

1. B1 `inbox_updated` on disconnect.
2. C4 UI health/status polish for disconnected integrations.
3. B2 SafeFetch private-network allowlist only if there is a real customer/internal-webhook case.

**Why second:** makes failures visible and operationally manageable.

### Release slice 3 — WhatsApp/data edge cases

1. B3 WhatsApp BSUID/coexistence unavailable messages.
2. Targeted UI rendering for unsupported/unavailable message bubbles.

**Why third:** useful but must not collide with OneLink Voice/Fonoster/custom WhatsApp work.

### Release slice 4 — product UX improvements

1. C2 XML/PFX attachments.
2. C1 Unread counts.
3. C3 Help Center enhancements if product decides Help Center is active priority.

**Why fourth:** product-facing, larger frontend/API QA surface.

### Release slice 5 — Captain schema/runtime

1. D1 Captain document migration/adaptation.
2. D2 OpenAI/audio guard decision.

**Why separate:** highest risk to AI/RAG semantics; needs dedicated DEV data checks.

---

## 7. QA and verification matrix

### Backend mandatory checks per slice

```bash
git status --short
bundle exec ruby -c <changed-ruby-files>
bundle exec rubocop <changed-ruby-files> --fail-level E
bundle exec rspec <targeted-specs>
git diff --check
```

### Frontend mandatory checks per slice

```bash
pnpm exec eslint <changed-js-vue-paths> --max-warnings=0
pnpm exec vitest run <targeted-vitest-specs>
python -m json.tool <changed-locale-json> >/dev/null
pnpm build:app
git diff --check
```

### Security/secret checks

```bash
git diff --cached --check
git diff --cached | grep -Ei 'token|secret|password|api[_-]?key|authorization|bearer' || true
```

Expected: only safe code/locale references; no credential values. Any credential-like value must be replaced with `[REDACTED]`.

### DEV smoke examples

- Login/settings route returns 200.
- Inbox settings page with disconnected state renders without JS errors.
- Twilio invalid signature request returns unauthorized in DEV/test.
- IMAP job handles synthetic timeout and continues.
- Sidebar unread counts render zero/non-zero cases if C1 implemented.
- Attachment upload accepts XML/PFX only if C2 implemented.

### PROD rule

- PROD deploy/restart only after explicit approval.
- Report SHA/branch/changed files/checks before requesting PROD approval.

---

## 8. Risks and mitigations

### Risk: Upstream change conflicts with OneLink customization

**Mitigation:** never cherry-pick blindly; inspect OneLink equivalent first and adapt minimal logic.

### Risk: Sidekiq cron upgrade changes scheduled jobs

**Mitigation:** split dependency upgrade, run scheduler compatibility check, verify cron jobs in DEV before PROD.

### Risk: SafeFetch allowlist becomes SSRF bypass

**Mitigation:** default deny, explicit allowlist, redirect tests, metadata/link-local denial tests.

### Risk: Unread counts cause sidebar IA regression

**Mitigation:** feature flag or staged rollout, preserve existing group visibility/order, targeted visual smoke.

### Risk: Captain document migration breaks semantic search

**Mitigation:** dry-run, backup/rollback snapshot, reindex plan, semantic search specs/evals before apply.

### Risk: WhatsApp upstream code conflicts with OneLink Voice/Fonoster stack

**Mitigation:** backport data/edge cases only; do not import Cloud Calling UI/controllers wholesale.

---

## 9. Open questions before implementation

1. Twilio endpoints: do we still actively support Twilio SMS/WhatsApp callbacks in production accounts?
2. Internal webhooks: is there a real customer case requiring private-network API inbox webhook URLs?
3. Help Center: is it currently product-critical for OneLink or should it stay deferred?
4. Unread counts: should badge/order behavior be behind feature flag for initial rollout?
5. Captain documents: do we have DEV data representative enough to dry-run field migration/reindex?
6. XML/PFX: should PFX be allowed upload+download only, or blocked for non-admin users?
7. Dependency upgrade: can `sidekiq-cron` be tested in DEV with real scheduled jobs before PROD?

---

## 10. Definition of done for the whole 4.14 native adoption

- P0/P1 backend/security gaps closed or explicitly marked not applicable with proof.
- Frontend shows integration/disconnect/unavailable states cleanly and localized.
- No OneLink Voice/Captain/working-hours regressions.
- All accepted product UX items have backend+frontend tests and DEV smoke.
- No secrets in diffs/logs.
- Each release slice has independent review.
- Final handoff includes branch, SHA, checks, DEV smoke, PROD touched/not touched.
