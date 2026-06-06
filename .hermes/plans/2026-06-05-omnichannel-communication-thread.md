# Omnichannel CommunicationThread Implementation Plan

> **For Hermes / OneLink:** двигаться по этому плану по слайсам. Не делать монолитный PR. Каждый слайс должен быть нативным, проверяемым и совместимым с текущими `Conversation` / `Inbox` / `ContactInbox` / `Message`.

**Goal:** сделать режим **Все каналы** как единое окно коммуникации с одним контактом, где сообщения из WhatsApp / Telegram / Email / SMS / Webchat / Voice видны в одной ленте, а отправка остаётся через выбранный нативный канал.

**Architecture:** не ломаем текущий Chatwoot/OneLink `Conversation`. Добавляем верхний слой `CommunicationThread`, который агрегирует несколько channel-specific `Conversation` одного `Contact`. Источник истины для доставки, webhooks, provider errors и channel constraints остаётся в старых нативных сущностях.

**Tech Stack:** Rails models/services/controllers/jobs, PostgreSQL indexes, Vue dashboard, existing conversations/message API/store patterns, RSpec, Vitest, ESLint.

---

## 0. Главные решения

### Делаем

- `CommunicationThread` = единый рабочий диалог с клиентом.
- Child `Conversation` остаются по одному каналу/inbox/source_id.
- В режиме **Все каналы** список показывает `CommunicationThread`, не отдельные `Conversation`.
- В окне диалога timeline объединяет сообщения из linked conversations.
- В composer оператор выбирает **Ответить через** конкретный канал.
- Channel capabilities показывают условия: доступен, нужен шаблон, нет прав, канал отключён, вне окна ответа.

### Не делаем

- Не делаем один обычный `Conversation` на все каналы.
- Не склеиваем всё только на фронте.
- Не отправляем одно сообщение сразу во все каналы по умолчанию.
- Не auto-merge контакты по имени/display name.
- Не ломаем WhatsApp 24h/template, email thread, voice lifecycle, delivery status.

---

## 1. Acceptance criteria

### Product / UX

- В выборе каналов есть режим **Все каналы**.
- При выборе **Все каналы** оператор видит список единых диалогов по клиентам.
- При открытии единого диалога видна общая хронология сообщений из всех каналов этого контакта.
- У каждого сообщения есть бейдж/иконка канала и inbox name.
- Composer показывает выбранный канал отправки.
- Оператор может переключить канал отправки, если канал доступен и есть права.
- Недоступные каналы показывают причину.

### Backend

- Входящее сообщение из любого канала линкует child conversation к `CommunicationThread`.
- Один active/open thread создаётся на `account_id + contact_id`, если нет явного разделения.
- Child conversations остаются нативными.
- Status/assignment/priority на thread работают как основной рабочий слой.
- Existing conversation APIs не ломаются.

### Performance

- Список thread загружается через агрегированные поля: `last_activity_at`, `last_message_preview`, `unread_count`.
- Timeline грузится с pagination/cursor, не вся история сразу.
- Frontend не делает N запросов по всем каналам для одного экрана.
- Индексы покрывают основные запросы.

### Safety

- Permissions по inbox учитываются.
- Agent видит/отправляет только через доступные inbox.
- WhatsApp/template/session constraints остаются provider-specific.
- Contact identity merge не автоматизируется небезопасно.

---

## 2. Слайсы реализации

## Slice 1 — Discovery and current-path map

**Objective:** перед кодом зафиксировать текущие пути Conversation/Inbox/Message и dirty tree, чтобы не сломать существующую систему.

**Commands to run after approval:**

```bash
cd /root/crafty/onelink/chatwoot

git status --short --branch --untracked-files=all
git diff --name-status

git grep -n "class Conversation" app enterprise
git grep -n "class Message" app enterprise
git grep -n "ContactInbox" app enterprise
git grep -n "SendReplyJob" app enterprise
git grep -n "conversationlist\|conversations" app/javascript/dashboard | head -120
```

**Deliverable:** краткая карта файлов:

- backend create/find conversation path;
- message creation path;
- send reply path;
- frontend conversation list path;
- frontend message timeline path;
- store/API paths.

**Do not edit code in this slice.**

---

## Slice 2 — Backend data model

**Objective:** добавить минимальную нативную модель единого диалога без влияния на старые conversations.

**Likely files:**

- Create migration: `db/migrate/*_create_communication_threads.rb`
- Create migration: `db/migrate/*_create_communication_thread_conversations.rb`
- Create model: `app/models/communication_thread.rb`
- Create model: `app/models/communication_thread_conversation.rb`
- Modify model carefully: `app/models/conversation.rb`
- Modify model carefully: `app/models/contact.rb`
- Add factories:
  - `spec/factories/communication_threads.rb`
  - `spec/factories/communication_thread_conversations.rb`
- Add model specs:
  - `spec/models/communication_thread_spec.rb`
  - `spec/models/communication_thread_conversation_spec.rb`

**Proposed schema:**

```ruby
create_table :communication_threads do |t|
  t.references :account, null: false, index: true
  t.references :contact, null: false, index: true
  t.integer :display_id, null: false
  t.integer :status, null: false, default: 0
  t.integer :priority, null: false, default: 0
  t.references :assignee, foreign_key: { to_table: :users }, index: true
  t.references :team, index: true
  t.datetime :last_activity_at
  t.integer :unread_count, null: false, default: 0
  t.timestamps
end

add_index :communication_threads, [:account_id, :display_id], unique: true
add_index :communication_threads, [:account_id, :contact_id, :status]
add_index :communication_threads, [:account_id, :last_activity_at]
```

```ruby
create_table :communication_thread_conversations do |t|
  t.references :account, null: false, index: true
  t.references :communication_thread, null: false, index: { name: 'idx_ctc_on_thread_id' }
  t.references :conversation, null: false, index: true
  t.references :inbox, null: false, index: true
  t.references :contact_inbox, index: true
  t.boolean :primary, null: false, default: false
  t.timestamps
end

add_index :communication_thread_conversations,
          [:account_id, :conversation_id],
          unique: true,
          name: 'idx_ctc_account_conversation_unique'
add_index :communication_thread_conversations,
          [:communication_thread_id, :inbox_id],
          name: 'idx_ctc_thread_inbox'
```

**TDD first:**

- spec: creates valid thread scoped to account/contact;
- spec: display_id unique per account;
- spec: one conversation can be linked once per account;
- spec: linked child conversation exposes thread.

**Verification:**

```bash
bundle exec rspec spec/models/communication_thread_spec.rb spec/models/communication_thread_conversation_spec.rb
ruby -c app/models/communication_thread.rb
ruby -c app/models/communication_thread_conversation.rb
```

---

## Slice 3 — Resolver/linking service

**Objective:** когда появляется conversation/message, находить или создавать thread и линковать conversation.

**Likely files:**

- Create: `app/services/communication_threads/resolver.rb`
- Create: `app/services/communication_threads/conversation_linker.rb`
- Add specs:
  - `spec/services/communication_threads/resolver_spec.rb`
  - `spec/services/communication_threads/conversation_linker_spec.rb`

**Service behavior:**

- Input: `conversation`.
- Validate account/contact present.
- Find active/open thread by `account_id + contact_id`.
- If absent, create thread.
- Link conversation via join table.
- Update thread aggregates:
  - `last_activity_at` from conversation/message;
  - `status` reopen on new incoming if needed;
  - `unread_count` later in dedicated slice.

**Important guardrails:**

- Idempotent: calling twice creates one link.
- Account scoped: never link cross-account.
- Does not merge contacts.
- Does not alter provider-specific message/conversation behavior.

**TDD first:**

- spec: creates a thread for first conversation of contact;
- spec: reuses same thread for second channel conversation of same contact;
- spec: does not link cross-account conversation;
- spec: idempotent on repeated calls;
- spec: updates `last_activity_at`.

**Verification:**

```bash
bundle exec rspec spec/services/communication_threads/resolver_spec.rb spec/services/communication_threads/conversation_linker_spec.rb
ruby -c app/services/communication_threads/resolver.rb
ruby -c app/services/communication_threads/conversation_linker.rb
```

---

## Slice 4 — Hook resolver into message/conversation lifecycle

**Objective:** все новые inbound/outbound messages/conversations автоматически оказываются в thread.

**Likely candidates to inspect first:**

- `app/models/message.rb`
- `app/models/conversation.rb`
- existing message listener/service paths
- provider incoming services under `app/services/**/incoming*`
- jobs under `app/jobs/channels/**`

**Preferred implementation:**

- Не размазывать вызовы по каждому provider.
- Найти общий lifecycle path после создания message/conversation.
- Добавить один сервисный вызов там, где уже есть account/contact/conversation.

**TDD first:**

- request/service spec for generic incoming message creates/links thread;
- spec for second channel message of same contact links to same thread;
- spec for outgoing reply also appears under same thread.

**Verification:**

```bash
bundle exec rspec <targeted_message_or_conversation_spec>
bundle exec rspec spec/services/communication_threads/resolver_spec.rb spec/services/communication_threads/conversation_linker_spec.rb
```

---

## Slice 5 — Backfill job/task

**Objective:** старые conversations должны получить threads безопасно и повторяемо.

**Likely files:**

- Create job: `app/jobs/communication_threads/backfill_job.rb`
- Or task: `lib/tasks/communication_threads.rake`
- Add specs:
  - `spec/jobs/communication_threads/backfill_job_spec.rb`
  - or `spec/tasks/communication_threads_backfill_spec.rb`

**Behavior:**

- Iterate by account/contact/conversation batches.
- For each conversation call resolver/linker.
- Idempotent.
- Safe to rerun.
- No contact merge.

**Operational mode:**

- First dry-run counts.
- Then apply.
- Log counts: scanned, created_threads, linked_conversations, skipped.

**Verification:**

```bash
bundle exec rspec spec/jobs/communication_threads/backfill_job_spec.rb
```

---

## Slice 6 — Thread API: list/show/timeline/channels

**Objective:** frontend получает готовый unified API, а не собирает всё сам.

**Likely files:**

- Routes: `config/routes.rb`
- Controller: `app/controllers/api/v1/accounts/communication_threads_controller.rb`
- Controller: `app/controllers/api/v1/accounts/communication_threads/messages_controller.rb`
- Jbuilder/serializer:
  - `app/views/api/v1/accounts/communication_threads/*.json.jbuilder`
- Request specs:
  - `spec/requests/api/v1/accounts/communication_threads_spec.rb`
  - `spec/requests/api/v1/accounts/communication_thread_messages_spec.rb`

**Endpoints:**

```text
GET /api/v1/accounts/:account_id/communication_threads
GET /api/v1/accounts/:account_id/communication_threads/:id
GET /api/v1/accounts/:account_id/communication_threads/:id/messages
GET /api/v1/accounts/:account_id/communication_threads/:id/channels
PATCH /api/v1/accounts/:account_id/communication_threads/:id
POST /api/v1/accounts/:account_id/communication_threads/:id/messages
```

**List response fields:**

- id;
- display_id;
- contact summary;
- status;
- priority;
- assignee/team;
- last_activity_at;
- last_message_preview;
- unread_count;
- channels summary.

**Timeline response fields:**

- message id;
- conversation_id;
- communication_thread_id;
- inbox_id;
- inbox name;
- channel_type;
- contact_inbox_id;
- message_type;
- content/content_type;
- attachments;
- delivery/status;
- created_at.

**TDD first:**

- spec: list returns only account-scoped threads;
- spec: timeline returns messages from linked conversations ordered by created_at;
- spec: pagination works;
- spec: agent without inbox access does not see restricted channel messages;
- spec: channels endpoint returns capabilities skeleton.

**Verification:**

```bash
bundle exec rspec spec/requests/api/v1/accounts/communication_threads_spec.rb spec/requests/api/v1/accounts/communication_thread_messages_spec.rb
ruby -c app/controllers/api/v1/accounts/communication_threads_controller.rb
```

---

## Slice 7 — Send message through selected channel

**Objective:** composer sends through one chosen native channel while staying inside unified window.

**Backend behavior:**

- Input: `communication_thread_id`, `target_contact_inbox_id` or `target_inbox_id`, content, attachments/template params.
- Validate thread/account/contact.
- Validate contact has selected contact_inbox/channel.
- Validate current user can send through inbox.
- Find or create child conversation for selected channel.
- Use existing native message creation/send path.
- Return message payload with channel metadata.

**Likely files:**

- Service: `app/services/communication_threads/send_message_service.rb`
- Controller action in messages controller.
- Specs:
  - `spec/services/communication_threads/send_message_service_spec.rb`
  - request spec for POST message.

**Channel constraints:**

- Do not reimplement provider rules in generic service.
- Ask channel capability/policy service before enabling send.
- WhatsApp template/free-text restrictions should remain in WhatsApp send path and capability response.

**TDD first:**

- spec: sends through existing linked conversation;
- spec: creates child conversation for selected contact_inbox if missing;
- spec: rejects inaccessible inbox;
- spec: rejects channel that belongs to another contact/account;
- spec: returns native message payload.

**Verification:**

```bash
bundle exec rspec spec/services/communication_threads/send_message_service_spec.rb spec/requests/api/v1/accounts/communication_thread_messages_spec.rb
```

---

## Slice 8 — Channel capabilities service

**Objective:** UI знает, какие каналы доступны и почему.

**Likely files:**

- Create: `app/services/communication_threads/channel_capabilities_builder.rb`
- Specs: `spec/services/communication_threads/channel_capabilities_builder_spec.rb`

**Capability payload:**

```json
{
  "contact_inbox_id": 123,
  "inbox_id": 7,
  "channel_type": "Channel::Whatsapp",
  "label": "WhatsApp Sales",
  "can_send_text": true,
  "can_send_attachments": true,
  "requires_template": false,
  "reply_window_open": true,
  "reauthorization_required": false,
  "disabled": false,
  "disabled_reason": null
}
```

**Initial version:**

- use generic availability + inbox permission;
- add known flags for WhatsApp reauthorization/template/session if existing code exposes them;
- do not invent unsupported provider data.

**Verification:**

```bash
bundle exec rspec spec/services/communication_threads/channel_capabilities_builder_spec.rb
```

---

## Slice 9 — Frontend API/store layer

**Objective:** добавить frontend data layer для unified threads без ломки обычных conversations.

**Likely files to inspect first:**

- `app/javascript/dashboard/api/conversations.js`
- `app/javascript/dashboard/store/modules/conversations.js`
- current conversation route/list components
- current message list components

**Likely new files:**

- `app/javascript/dashboard/api/communicationThreads.js`
- `app/javascript/dashboard/store/modules/communicationThreads.js` or Pinia store if the surface already moved there
- Tests:
  - `app/javascript/dashboard/api/communicationThreads.spec.js`
  - store/composable specs if pattern exists.

**Frontend API methods:**

- `getThreads(params)`
- `getThread(id)`
- `getMessages(threadId, params)`
- `getChannels(threadId)`
- `sendMessage(threadId, payload)`
- `updateThread(threadId, payload)`

**Verification:**

```bash
pnpm exec vitest --no-watch --no-cache --no-coverage app/javascript/dashboard/api/communicationThreads.spec.js
pnpm exec eslint app/javascript/dashboard/api/communicationThreads.js
```

---

## Slice 10 — Sidebar/channel selector: “Все каналы” mode

**Objective:** в месте выбора каналов добавить режим **Все каналы**, который открывает unified list.

**Likely files to inspect/modify:**

- sidebar/channel list components under `app/javascript/dashboard/components-next/sidebar/`
- conversation list routes/components under `app/javascript/dashboard/routes/dashboard/conversation/`
- route query handling for inbox/channel filters
- locale files:
  - `app/javascript/dashboard/i18n/locale/ru/*.json`
  - `app/javascript/dashboard/i18n/locale/en/*.json`
  - `app/javascript/dashboard/i18n/locale/kk/*.json`

**UX:**

- **Все каналы** as parent/all selector.
- List rows show contact + channel badges.
- Channel-specific filters still work.

**TDD/Vitest first if component tests exist:**

- all-channels item renders;
- click navigates to unified list mode;
- selected state works;
- channel-specific mode still works.

**Verification:**

```bash
pnpm exec vitest --no-watch --no-cache --no-coverage <sidebar_or_route_spec>
pnpm exec eslint <changed_vue_js_files>
node -e "JSON.parse(require('fs').readFileSync('<ru_locale_file>', 'utf8')); JSON.parse(require('fs').readFileSync('<en_locale_file>', 'utf8')); JSON.parse(require('fs').readFileSync('<kk_locale_file>', 'utf8'))"
```

---

## Slice 11 — Unified conversation list UI

**Objective:** показать список `CommunicationThread` вместо обычных conversations в режиме **Все каналы**.

**Likely files:**

- New/modified list component under conversation route.
- Existing conversation card component reuse where possible.
- Add channel badges component if none exists.

**UI row fields:**

- Contact avatar/name.
- Last message preview.
- Channel icons summary.
- Status/priority/unread.
- Assignee/team.
- Last activity.

**Performance:**

- Infinite scroll/pagination using backend list.
- No per-row extra request for channels.

**Verification:**

```bash
pnpm exec vitest --no-watch --no-cache --no-coverage <unified_list_spec>
pnpm exec eslint <changed_vue_js_files>
```

---

## Slice 12 — Unified timeline UI

**Objective:** одно окно показывает merged timeline with channel badges.

**Likely files:**

- Current message list path, likely `MessageList.vue` / `Message.vue` under dashboard conversation components.
- New adapter/composable to map unified message payload to existing message bubble shape.
- Channel badge component.

**Rules:**

- Reuse existing message bubble components.
- Do not build a custom mini-transcript viewer.
- Each bubble keeps `conversation_id` and `message_id`.
- Activity/call/payment events later can enter as timeline events.

**Verification:**

```bash
pnpm exec vitest --no-watch --no-cache --no-coverage <message_timeline_spec>
pnpm exec eslint <changed_vue_js_files>
```

---

## Slice 13 — Composer channel selector

**Objective:** внутри unified window оператор выбирает канал отправки.

**Likely files:**

- Reply box / composer components under dashboard conversation message composer.
- Existing WootWriter / ReplyBottomPanel path.
- New channel selector component:
  - `app/javascript/dashboard/components-next/conversation/ChannelReplySelector.vue`

**UX:**

- Label: `Ответить через`.
- Default selected channel = last incoming accessible channel.
- Dropdown shows all available contact channels.
- Disabled channel shows reason.
- If WhatsApp requires template, show explicit state and route to template mode if supported.

**Frontend payload:**

```json
{
  "target_contact_inbox_id": 123,
  "content": "...",
  "content_kind": "free_text",
  "template_params": null,
  "attachment_ids": []
}
```

**Verification:**

```bash
pnpm exec vitest --no-watch --no-cache --no-coverage <composer_selector_spec>
pnpm exec eslint <changed_vue_js_files>
```

---

## Slice 14 — Status/assignment/resolve sync

**Objective:** thread status is primary, child conversations stay compatible.

**Backend behavior:**

- Updating thread status updates thread.
- Optional compatibility sync to child conversations for old filters/reports.
- New incoming from any linked child reopens thread.
- Assignment/team changes on thread optionally mirror to child conversations.

**Likely files:**

- `app/services/communication_threads/status_update_service.rb`
- `app/services/communication_threads/assignment_update_service.rb`
- controller update action.
- specs.

**TDD first:**

- resolve thread resolves linked active conversations;
- incoming child message reopens thread;
- assignment changes are account-scoped;
- no cross-account child updates.

**Verification:**

```bash
bundle exec rspec spec/services/communication_threads/status_update_service_spec.rb spec/services/communication_threads/assignment_update_service_spec.rb
```

---

## Slice 15 — Realtime/unread/list refresh

**Objective:** unified list and active thread update without hard reload.

**Rules:**

- Reuse existing ActionCable/event patterns.
- Coalesce aggregate refreshes.
- Do not call expensive counts on every event.
- Active thread receives appended message event.
- List row updates last_message/unread/channel summary.

**Likely files:**

- existing event listeners/store handlers for conversations/messages;
- new communicationThread event handling.

**Verification:**

- store/composable specs for receiving event;
- manual DEV UI smoke later after code-slice green.

---

## Slice 16 — Permissions and visibility hardening

**Objective:** protect cross-inbox access in unified timeline.

**Rules:**

- Agent can see messages only from inboxes they can access unless product explicitly grants thread-level full access.
- Send only through accessible inboxes.
- If hidden messages exist, UI may show neutral notice: `Есть сообщения из каналов, к которым у вас нет доступа`.
- Admin/account owner can see all account-scoped channels.

**Tests:**

- agent with only WhatsApp inbox sees WhatsApp timeline only;
- cannot send through Telegram inbox without access;
- admin sees all linked channels;
- no cross-account leakage.

---

## Slice 17 — Captain/AI integration

**Objective:** Captain sees unified customer context but sends through selected/native channel.

**Later files to inspect:**

- Captain context builders.
- Captain send message/native tools.
- ToolRegistry.

**Rules:**

- Context includes channel metadata per message.
- Tools accept `communication_thread_id` + selected channel/contact_inbox.
- Captain must respect channel capabilities.
- WhatsApp outside 24h should not free-text.

**This is not part of first MVP unless user asks.**

---

## Slice 18 — Automation/reporting integration

**Objective:** avoid duplicate automation and add future thread-level events.

**MVP:**

- Legacy automation remains on child conversation.
- Thread aggregates update passively.

**Later:**

- Add event family:
  - `communication_thread_created`
  - `communication_thread_updated`
  - `communication_thread_reopened`
  - `communication_thread_resolved`
  - `communication_thread_message_created`

**Risk:** duplicate triggers if both child and parent events fire. Must design explicit source context before enabling.

---

## 3. Performance plan

### MVP performance

- Thread list uses `communication_threads.last_activity_at`, `unread_count`, preview fields.
- Timeline query uses linked `conversation_id IN (...)` with pagination.
- Indexes on `communication_thread_conversations.communication_thread_id`, `conversation_id`, `inbox_id`.
- Limit 30–50 messages per page.

### Production read-model if needed

Create later:

```text
communication_timeline_events
- account_id
- communication_thread_id
- eventable_type
- eventable_id
- conversation_id
- inbox_id
- contact_inbox_id
- channel_type
- occurred_at
```

Use when:

- timeline needs calls/payments/tasks/touches mixed with messages;
- message volume per contact is high;
- query plan becomes expensive;
- realtime/event replay needs normalized feed.

Do not add projection in first slice unless benchmarks/UX require it.

---

## 4. Rollout strategy

1. Add backend behind feature flag, no UI exposure.
2. Backfill DEV/test data.
3. Expose API for internal testing.
4. Add frontend **Все каналы** behind feature flag.
5. Enable for DEV account.
6. Manual QA with real cases.
7. Only after QA, consider production rollout.

Potential feature flag names:

- `communication_threads`
- `omnichannel_threads`
- `unified_conversations`

Prefer product copy: **Единые диалоги** / **Все каналы**.

---

## 5. Manual QA cases

### Case A — Same contact, two channels

1. Contact has WhatsApp and Telegram contact_inboxes.
2. WhatsApp message arrives.
3. Telegram message arrives.
4. Open **Все каналы**.
5. Verify one thread with both messages in order.

Expected: one unified window, channel badges visible.

### Case B — Reply through selected channel

1. Open unified thread.
2. Select Telegram in composer.
3. Send message.
4. Verify message belongs to Telegram child conversation.

Expected: no WhatsApp send, no duplicate channel send.

### Case C — Restricted inbox permission

1. Agent has access only to WhatsApp inbox.
2. Thread has WhatsApp + Telegram.
3. Open thread.

Expected: agent sees WhatsApp messages only or hidden-channel notice; cannot send via Telegram.

### Case D — WhatsApp needs template

1. Contact has WhatsApp outside reply window.
2. Composer shows WhatsApp disabled/requires template.
3. Telegram/email still available if configured.

Expected: no invalid free-text WhatsApp send.

### Case E — Resolve/reopen

1. Resolve unified thread.
2. New incoming message arrives from any linked channel.

Expected: parent thread reopens and appears in **Все каналы**.

### Case F — Voice event later

1. Voice call conversation linked to same contact.
2. Timeline includes call summary/recording as event.

Expected: call appears as communication context, not separate hidden conversation.

---

## 6. Verification matrix

### Backend minimum pack

```bash
bundle exec rspec \
  spec/models/communication_thread_spec.rb \
  spec/models/communication_thread_conversation_spec.rb \
  spec/services/communication_threads/resolver_spec.rb \
  spec/services/communication_threads/conversation_linker_spec.rb \
  spec/requests/api/v1/accounts/communication_threads_spec.rb \
  spec/requests/api/v1/accounts/communication_thread_messages_spec.rb
```

### Frontend minimum pack

```bash
pnpm exec vitest --no-watch --no-cache --no-coverage <changed_specs>
pnpm exec eslint <changed_vue_js_files>
```

### Syntax / static checks

```bash
ruby -c <changed_ruby_files>
git diff --check
node -e "JSON.parse(require('fs').readFileSync('<locale_file>', 'utf8'))"
```

### Final code-slice gate

- RSpec targeted pass.
- Vitest targeted pass.
- ESLint touched files 0 errors.
- Ruby syntax pass.
- Locale JSON parse pass.
- `git diff --check` pass.
- Independent review pass before commit/push.

---

## 7. Risks and mitigations

### Risk: heavy queries

Mitigation: thread aggregates, pagination, indexes, projection later.

### Risk: duplicated automations

Mitigation: MVP keeps automation on child conversations only; parent events later with explicit source context.

### Risk: permissions leakage

Mitigation: timeline filters by accessible inboxes; send validates inbox membership/account access.

### Risk: contact misidentification

Mitigation: no unsafe auto-merge; link only same `contact_id`. Suggested merge later.

### Risk: breaking existing conversation UI/API

Mitigation: do not mutate existing `/conversations` behavior; add new API surface.

### Risk: channel constraints ignored

Mitigation: capabilities builder + provider-specific send path remains authoritative.

---

## 8. Definition of Done for MVP

- `CommunicationThread` model and linker exist.
- Incoming/created conversations link to thread.
- Backfill exists and is idempotent.
- API returns thread list and unified timeline.
- UI has **Все каналы** mode.
- Unified window shows channel badges.
- Composer can send through selected available channel.
- Permissions are covered by tests.
- Targeted backend/frontend checks pass.
- DEV smoke confirms main user cases.

---

## 9. Execution rule

Двигаться строго по чеклисту:

1. Перед каждым слайсом обновить статус в этом файле или отдельном tracker.
2. Сначала тест/спека, затем код.
3. Не смешивать unrelated dirty-tree изменения.
4. После слайса — targeted verification.
5. После нескольких слайсов — independent review.
6. Не коммитить/пушить без отдельного подтверждения.

---

## 10. Current progress tracker

Updated: 2026-06-06 — communication-thread MVP code slice through Slice 18 is implemented and targeted-check green after permission/realtime/Captain hardening. Full product plan is still not fully closed: DEV browser smoke plus post-MVP provider/live-channel hardening remain.

- [x] Slice 1 — Discovery and current-path map
- [x] Slice 2 — Backend data model
- [x] Slice 3 — Resolver/linking service
- [x] Slice 4 — Hook resolver into lifecycle
- [x] Slice 5 — Backfill job/task
- [x] Slice 6 — Thread API
- [x] Slice 7 — Send through selected channel: selected existing child conversations and unlinked selected contact inboxes create/link native child conversations; multipart attachment JSON metadata, template params, and delivery policy are preserved.
- [>] Slice 8 — Channel capabilities: API/UI contract, unlinked-channel aliases, and provider-aware WhatsApp template-window semantics are implemented; deeper provider/live-channel hardening remains post-MVP work.
- [x] Slice 9 — Frontend API/store
- [x] Slice 10 — Sidebar/channel selector “Все каналы”
- [x] Slice 11 — Unified conversation list UI
- [x] Slice 12 — Unified timeline UI
- [x] Slice 13 — Composer channel selector
- [x] Slice 14 — Status/assignment/resolve sync
- [x] Slice 15 — Realtime/unread/list refresh: child message/update fanout, loaded-thread append, backend `communication_thread.updated`, and frontend aggregate-thread handler are implemented/verified.
- [x] Slice 16 — Permissions hardening
- [x] Slice 17 — Captain/AI integration: Captain runtime context now includes communication-thread/channel metadata, and `send_message_to_conversation` accepts `communication_thread_id` + selected channel/contact-inbox targets while preserving native child-conversation delivery/capability checks.
- [x] Slice 18 — Automation/reporting integration: MVP remains passive by design; legacy automation/reporting stay bound to child conversations, with regression coverage proving no thread-level reporting association is introduced.

Latest targeted verification:

- Backend RSpec communication-thread/API/model/service/job/listener pack: 77 examples, 0 failures.
- Backend RSpec Captain/AI communication-thread pack: `context_fields_spec`, `http_request_executor_spec`, `assistant_spec`, `custom_tool_spec`, `agentable_spec`, `agent_runner_service_spec`, `native_ops_tools_spec` — 302 examples, 0 failures.
- Backend RSpec automation/reporting/message regression pack: `message_spec`, `reporting_event_spec`, `automation_rule_listener_spec` — 155 examples, 0 failures.
- Frontend Vitest helper/route/URL/ActionCable/composer/store pack: 238 tests, 0 failures.
- Targeted ESLint: 0 errors; 4 existing dynamic-i18n warnings in `ChatList.vue` and `MessagesView.vue`.
- Targeted Ruby syntax: OK for staged Ruby files and hardening updates.
- `config/features.yml` YAML parse: OK.
- Conversation locale JSON parse: OK for en/ru/kk.
- Targeted `git diff --check`: OK for staged/owned hardening paths.
- Targeted RuboCop with `--fail-level E`: exit 0; remaining reported offenses are convention/warning-level metrics/class-length/style issues in existing large Rails/Captain/schema/spec files, not error-level blockers.

Independent review / handoff notes:

- Fixed blocker: communication-thread UI/API is behind `communication_threads` account feature flag (`config/features.yml`, route meta, frontend route guard, backend API guard).
- Fixed blocker: default-disabled accounts no longer auto-create/update communication threads or expose thread metadata in realtime/Captain contexts until `communication_threads` is enabled.
- Fixed blocker: existing linked child-channel sends now use the same native conversation permission scope as the API timeline/list; hidden child conversations are rejected before message creation.
- Fixed blocker: dashboard realtime `communication_thread.updated` broadcasts are filtered per recipient, so agents only receive channel IDs they can see.
- Fixed blocker: Captain/Copilot communication-thread sends pass the same accessible-link scope into native `CommunicationThreads::MessageCreateService`; the selected channel path no longer bypasses backend permission/capability checks.
- Slice 17 fixed Captain/AI gap natively: runtime context exposes thread/channel metadata, and `send_message_to_conversation` accepts `communication_thread_id` + selected channel/contact-inbox targets while preserving native child-conversation delivery/capability checks.
- Slice 18 keeps MVP automation/reporting safe: no parent thread automation/reporting events are enabled yet, avoiding duplicate triggers until explicit source-context design exists.
- Code-slice is path-scoped green; the repo dirty tree still contains unrelated voice/telephony/LLM changes that must stay out of this communication-thread commit.
- No DEV browser smoke was run in this slice; main manual cases still need DEV validation before product-level PASS.
- Full product plan remains open only for DEV browser smoke and post-MVP provider/live-channel hardening (including deeper Slice 8 provider semantics); code slices 1–18 are implemented/targeted-green.
