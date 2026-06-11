# OneLink MCP Full Tool Audit Plan

**Goal:** протестировать весь OneLink MCP surface account 530 так, чтобы каждая tool/API была понятна внешним агентам, нативно выполняла свою функцию, была безопасной, структурированной, надежной и покрывала реальные кейсы проекта.

**Target:** `https://dev.one-link.kz/api/v1/accounts/530/mcp`

**Scope:** DEV only. PROD не трогать. Секреты/токены не печатать. Все тестовые данные создавать с маркером `mcp-audit-<timestamp>` и убирать после проверки.

---

## 1. Definition of Done

MCP surface считается готовым только если:

- все advertised tools реально вызваны хотя бы один раз;
- `initialize`, `ping`, `tools/list` стабильны и быстрые;
- каждая tool имеет понятные name/description/schema;
- required/optional params соответствуют реальному runtime;
- enum/ID/date/limit params описаны так, чтобы агент не угадывал;
- read tools возвращают structured payload и bounded results;
- mutation/high-risk tools не меняют данные без confirmation;
- positive mutation кейсы проходят на изолированных DEV фикстурах;
- cleanup доказан через MCP или явно зафиксирован lifecycle gap;
- normal invalid input дает structured 4xx/not-found/validation error, не 500;
- нет secret/token/raw URL leakage;
- нет timeouts на bounded calls;
- blind-agent сценарии проходят без знания внутреннего кода.

---

## 2. Artifacts to Produce

Create audit output files under a run directory, например:

`tmp/mcp_audit/<run_id>/`

Required artifacts:

- `inventory.json` — полный каталог tools.
- `inventory.csv` — компактная таблица для ревью.
- `static_contract_findings.md` — schema/description/risk/output issues.
- `runtime_results.jsonl` — один JSON объект на каждый вызов.
- `runtime_summary.csv` — status/latency/result per tool.
- `cleanup_report.md` — что создано и чем удалено.
- `blind_agent_scenarios.md` — результаты user-case проверки.
- `final_report.md` — итоговая оценка и backlog.

---

## 3. Scoring Rubric per Tool

Каждую tool оценить по 10 критериям.

### 3.1 Name

- понятное имя;
- нет дублей и конфликтов;
- совпадает с domain action: `search_*`, `get_*`, `create_*`, `update_*`, `cancel_*`, `api__...`.

### 3.2 Description

- агент понимает, когда tool применять;
- указаны account/current conversation/current contact constraints;
- описаны side effects;
- нет обещаний шире, чем runtime реально умеет.

### 3.3 Input Schema

- корректные types;
- required/optional совпадают с runtime;
- enum values перечислены;
- `*_id` явно описаны как IDs;
- есть `limit`, pagination, date/window filters где нужно;
- для high-risk есть reason/confirmation/idempotency semantics.

### 3.4 Agent Usability

- агент может найти нужные IDs через catalog/search/list tools;
- mutation tools не заставляют угадывать `stage_id`, `team_id`, `resource_id`, `template_name`;
- есть companion catalog tools для pipelines/stages/users/teams/templates/custom fields.

### 3.5 Native Domain Correctness

- использует нативные OneLink domain services/models;
- соблюдает бизнес-правила проекта;
- не является сырым хаком вокруг controller route;
- public/customer-agent vs assistant/copilot scopes разделены правильно.

### 3.6 Security / Permissions

- account isolation;
- role/admin gates;
- feature flags;
- no cross-account record access;
- no raw token/secret/signed URL leakage.

### 3.7 Confirmation / Mutation Safety

- без `_confirm` нет mutation;
- confirmation-required metadata соответствует поведению;
- pending confirmation не исполняет действие;
- approval проверяет same tool/args fingerprint;
- retries/idempotency не создают дубли.

### 3.8 Output Contract

- structured JSON, не свободный текст;
- stable top-level `action`, entity IDs, status, timestamps;
- nested domain payload сохранен;
- errors structured and actionable.

### 3.9 Reliability / Performance

- bounded latency;
- no Rack/MCP timeout;
- expensive list tools require limits;
- semantic/RAG tools degrade to lexical/structured unavailable, not timeout.

### 3.10 Lifecycle / Cleanup

- created entities can be closed/deleted/archived through MCP;
- if no cleanup tool exists — mark lifecycle gap;
- test fixtures removed after run.

Grades:

- `A`: ready for external agents.
- `B`: works, minor schema/description fixes.
- `C`: partially works, agent may misuse.
- `D`: unreliable/unclear/unsafe.
- `BLOCKER`: timeout, 500, confirmation bypass, wrong mutation, secret leak.

---

## 4. Phase 1 — Transport and Catalog Audit

### Objective

Prove MCP endpoint is reachable and catalog is complete before tool execution.

### Checks

1. JSON-RPC `initialize`.
2. JSON-RPC `ping`.
3. JSON-RPC `tools/list`.
4. Count advertised tools.
5. Save raw catalog with redacted auth.
6. Detect duplicate names.
7. Detect source groups:
   - native Captain semantic tools;
   - OpenAPI fallback `api__...` tools.
8. Extract metadata:
   - risk level;
   - confirmation required;
   - scopes;
   - description;
   - input schema;
   - output hints.

### Exit Criteria

- catalog loads under latency budget;
- tool count matches Hermes MCP test count;
- inventory files generated.

---

## 5. Phase 2 — Static Contract Audit

### Objective

Find tool quality issues without mutations.

### Checks per Tool

- name clarity;
- group/domain consistency;
- description completeness;
- schema correctness;
- required vs optional mismatch;
- ambiguous IDs;
- missing enums;
- missing limit/pagination;
- confirmation metadata vs risk level;
- duplicated native/OpenAPI functions;
- dangerous OpenAPI writes exposed without clear gate.

### Output

`static_contract_findings.md` with sections:

- P0 blockers;
- P1 agent-usability issues;
- P2 naming/docs cleanup;
- domain-specific patterns.

---

## 6. Phase 3 — Safe Runtime Invocation of Every Tool

### Objective

Invoke every advertised tool at least once with safe/minimal arguments.

### Harness Requirements

For each call store:

- `run_id`;
- `tool_name`;
- `domain`;
- `args_profile`;
- `status`: pass/fail/expected_error/confirmation_blocked/timeout;
- `latency_ms`;
- `result_type`;
- `error_class`;
- `mutation_expected`;
- `mutation_observed`;
- `cleanup_marker`;
- redacted output sample.

### Safe Invocation Rules

- read/list/search tools: use bounded `limit`, page, short date range;
- get tools: use known valid fixture ID and one invalid ID;
- mutation tools: first call without confirmation and assert no mutation;
- OpenAPI non-GET: first call without confirmation and assert blocked;
- high-risk tools: no positive mutation until separately approved by scenario plan;
- all calls timeout-bounded.

### Exit Criteria

- `invoked_unique == advertised_tools` or missing list documented;
- no unexpected server 500/timeouts without blocker ticket;
- confirmation-required tools counted and blocked correctly.

---

## 7. Phase 4 — Domain Positive Scenarios on DEV Fixtures

Use marker `mcp-audit-<run_id>` in all records.

### 7.1 Knowledge / FAQ / Articles

Tools:

- `search_documentation`
- `list_captain_documents`
- `faq_lookup`
- `get_article`
- `search_articles`

Cases:

- normal search;
- empty search;
- missing document/article;
- semantic unavailable fallback;
- source IDs and trace present;
- no raw internals/secrets.

### 7.2 Conversations / Messages

Tools:

- `get_conversation`
- `search_conversations`
- `send_message_to_conversation`
- `add_private_note`
- `assign_conversation`
- `resolve_conversation`
- `update_priority`
- `retry_failed_message`
- `edit_message`
- `translate_message`
- conversation labels.

Cases:

- filters/limit;
- get existing/missing;
- private note structured payload;
- public send route safety;
- status/priority mutation returns final state;
- failed message retry only on failed messages;
- label add/remove idempotency.

### 7.3 Contacts / Companies

Tools:

- `get_contact`
- `search_contacts`
- `create_contact`
- `update_contact`
- `merge_contacts`
- `get_company`
- `search_companies`
- `create_company`
- `update_company`.

Cases:

- search by name/email/phone;
- create idempotency;
- custom attributes;
- cross-account rejection;
- merge confirmation gate;
- structured output with safe fields only.

### 7.4 CRM Deals

Tools:

- `get_deal`
- `search_deals`
- `list_deal_pipelines`
- `list_deal_stages`
- `list_deal_custom_fields`
- `create_deal`
- `update_deal`
- `transition_deal_stage`
- `add_deal_comment`
- `get_deal_timeline`.

Cases:

- pipeline/stage catalog before mutation;
- duplicate stage names resolved by pipeline/stage_id;
- amount/currency AI-safe;
- custom fields from catalog;
- transition native;
- timeline structured;
- archive/delete lifecycle gap if cleanup unavailable.

### 7.5 CRM Tasks

Tools:

- `get_task`
- `search_tasks`
- `list_task_custom_fields`
- `create_task`
- `update_task`
- `change_task_status`
- `complete_task`
- `add_task_comment`
- `get_task_timeline`.

Cases:

- create linked to deal/conversation;
- status transition native;
- completion idempotency;
- assignee/team catalog use;
- invalid task returns structured not-found;
- output includes `task_id`, `status_id`, `completed_at`.

### 7.6 Scheduling / Appointments

Tools:

- `search_appointments`
- `get_appointment`
- `list_scheduling_resources`
- `search_scheduling_resources`
- `get_scheduling_resource_schedule`
- `get_scheduling_resource_availability`
- `search_scheduling_services`
- `search_available_slots`
- `create_appointment`
- `update_appointment`
- `cancel_appointment`
- payment tools.

Cases:

- slots by resource/service/time range;
- invalid resource/service combo;
- duration and timezone handling;
- create/update/cancel lifecycle;
- payment admin/finance gates;
- structured appointment IDs/status/times.

### 7.7 Outbound Touches / Confirmations

Tools:

- `list_channel_templates`
- `create_touch`
- `cancel_touch`
- `delete_touch`
- `cancel_touches`
- `create_touch_plan`
- `apply_touch_plan`
- `archive_touch_plan`
- `request_confirmation`
- `resolve_confirmation`.

Cases:

- WhatsApp template/window policy;
- delayed touch schedule;
- attachment/template params;
- auto-cancel on incoming;
- touch plan apply count;
- confirmation request and resolve paths;
- cleanup all touches/plans.

### 7.8 Campaigns / Webhooks / Labels / Canned Responses / Macros

Tools:

- campaigns list/preview/analytics/retry;
- webhook create/update;
- label create/update/remove;
- canned response search/create;
- macro execution.

Cases:

- admin-only gates;
- high-risk confirmation;
- webhook URL/token redaction;
- preview dry-run only;
- retry only failed deliveries;
- structured payloads.

### 7.9 Channel / WhatsApp Diagnostics

Tools:

- `get_channel_health`
- `get_whatsapp_web_diagnostics`
- `reconnect_whatsapp_web`
- WhatsApp REST fallback tools.

Cases:

- diagnostics read-only;
- reconnect confirmation/permission;
- QR/session artifacts not leaked;
- provider differences: WA Web vs Cloud vs Telegram.

### 7.10 Observability / Health / Trace

Tools:

- `get_account_health`
- `get_recent_account_errors`
- `get_tool_execution_log`
- `trace_ai_response`
- `trace_message_delivery`.

Cases:

- account-scoped output;
- bounded windows;
- redacted args/results;
- invalid trace/message ID returns structured error;
- enough fields for RCA.

### 7.11 OpenAPI Fallback Tools

Tools:

- all `api__...` tools.

Cases:

- GET/list with pagination;
- missing ID returns structured 404, not 500;
- POST/PATCH/DELETE without confirmation blocked;
- nested Rails dispatch stable;
- overlap with native semantic tools documented.

---

## 8. Phase 5 — Blind-Agent Usability Test

Give a fresh agent only MCP catalog and realistic tasks.

Scenarios:

1. Найти contact, посмотреть conversation history, добавить private note.
2. Найти deal, перейти на нужный stage, добавить comment.
3. Найти свободный slot и создать appointment.
4. Создать follow-up touch с approved template.
5. Сделать RCA по failed delivery через health/trace tools.
6. Проверить WhatsApp Web inbox diagnostics.
7. Создать/update contact/company/task из пользовательского запроса.

Evaluate:

- selected correct tools;
- did not guess IDs;
- used catalog/list/search before mutation;
- handled errors;
- did not bypass confirmation;
- continued workflow using structured output.

---

## 9. Cleanup Plan

After each run:

- delete/archive test contacts;
- delete/archive CRM deals/tasks where possible;
- cancel/delete appointments/touches/plans;
- remove labels/webhooks/canned responses/custom filters created by run;
- verify no active records with marker `mcp-audit-*` remain;
- if cleanup impossible via MCP, mark lifecycle gap and use Rails runner only as documented DEV fallback.

Cleanup report must include:

- created counts;
- cleaned counts;
- leftovers;
- cleanup method;
- lifecycle gaps.

---

## 10. Final Report Format

`final_report.md` structure:

1. Verdict:
   - all tools invoked: yes/no;
   - code changed: yes/no;
   - PROD touched: no.
2. Counts:
   - advertised;
   - invoked;
   - pass A/B/C/D;
   - blockers;
   - confirmation-blocked OK;
   - cleanup OK/gaps.
3. P0 blockers:
   - security;
   - confirmation bypass;
   - secret leak;
   - wrong mutation;
   - timeout;
   - 500 on normal invalid input.
4. P1 issues:
   - unclear schema;
   - missing catalog tools;
   - weak output contract;
   - agent-usability risks.
5. P2 issues:
   - naming;
   - descriptions;
   - consistency.
6. Domain summaries.
7. Fix priority list.
8. Untested/blocked areas.
9. Cleanup proof.
10. DEV health proof.

---

## 11. Execution Order

1. Catalog/static audit only.
2. Safe runtime invocation of read-only and expected-error paths.
3. Confirmation-gate audit for all mutation/high-risk tools.
4. Positive mutation scenarios on isolated fixtures.
5. Cleanup verification.
6. Blind-agent usability test.
7. Final report and prioritized fix backlog.

---

## 12. Approval Boundary

Before positive mutation phase, explicitly approve:

- which DEV account/inboxes/conversations/resources may be used;
- whether creating contacts/deals/tasks/appointments/touches/webhooks is allowed;
- cleanup fallback via Rails runner if MCP lifecycle is missing;
- whether live provider/channel sends are allowed or must stay dry-run/private-note only.
