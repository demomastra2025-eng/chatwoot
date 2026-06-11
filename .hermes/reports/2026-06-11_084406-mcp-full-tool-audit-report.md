# OneLink MCP full-tool audit — DEV account 530

Дата: `2026-06-11`  •  окружение: `DEV`  •  endpoint: `https://dev.one-link.kz/api/v1/accounts/530/mcp`

## Verdict

**PARTIAL PASS / внешний MCP usable, но не production-perfect.**

- Все advertised MCP tools реально вызваны минимум один раз: `248/248`.
- Confirmation gate для mutating/high-risk surface: `146/146` no-confirm probes вернули `requires _confirm`, bypass/side-effect не найден.
- Representative positive mutations на DEV фикстурах прошли: support, CRM, scheduling, outbound/confirmation, observability.
- Cleanup: через MCP частично, затем DEV Rails fallback для связанных фикстур; финальная проверка marker-артефактов = `0`.
- PROD не трогал. На момент audit-run product source code не менял; после аудита выполнен отдельный remediation pass ниже.
- Главные остаточные проблемы: error-shape/agent UX, lifecycle cleanup, медленный knowledge path, transient catalog timeout/flakiness.

## Scope / источник плана

- План: `/root/crafty/onelink/chatwoot/.hermes/plans/2026-06-11_081149-mcp-full-tool-audit-plan.md`.
- Использован и расширен существующий подход из OneLink QA/MCP references: full-tool audit, confirmation-gates audit, real-user-case audit.
- Account: `530`; credentials/token intentionally not printed.

## Inventory

- Tools advertised: `248`
- Resources advertised: `4`
- Source split: Captain/native `98`, OpenAPI fallback `150`
- Risk split: low `102`, medium `71`, high `75`
- Mutation-like tools: `134`; read/catalog-like: `114`
- Tools with `_confirm` param / mutation gate surface: `146`

## Runtime coverage

- Full harness: `282 pass / 3 fail`. The 3 failures were catalog/resource hard timeouts in that run: `tools/list`, `tools/catalog`, `openapi/tools`.
- Follow-up refresh proved same catalog/resources recover fast: `initialize 201ms`, `ping 61ms`, `tools/list 345ms`, `resources/list 92ms`, resources `95–310ms`. Treat as flakiness/perf gap, not persistent auth/transport failure.
- Remaining missing coverage harness: `20/20 pass`; final unique advertised invocation: `248/248`, `missing=[]`.
- Real user-case harness: `76 pass / 1 fail`; the only fail was cleanup-only `api__contactdelete` after linked artifacts were created.

## Real scenarios covered

- `00_transport_and_catalogs` — transport/catalog/resources: pass `11`, fail `0`, tools `8`
- `01_real_support_triage` — support triage: contact/conversation/label/note/assign/message/notify/trace: pass `12`, fail `0`, tools `12`
- `02_real_knowledge_answer` — knowledge: docs/FAQ/documents/articles: pass `4`, fail `0`, tools `4`
- `03_real_sales_pipeline` — CRM: pipeline/stage/deal/task/timeline: pass `14`, fail `0`, tools `14`
- `04_real_booking_flow` — scheduling: resource/service/availability/appointment/payment: pass `15`, fail `0`, tools `15`
- `05_real_outbound_confirmation` — outbound/confirmation: templates/preview/touch/confirmation: pass `5`, fail `0`, tools `5`
- `06_real_gates_observability` — safety/observability: gates/health/errors/tool-log/traces: pass `7`, fail `0`, tools `7`
- `99_mcp_cleanup` — MCP cleanup path: pass `8`, fail `1`, tools `9`

## Confirmation and mutation safety

- OpenAPI non-GET/mutation fallback no-confirm probes: blocked before Rails action with `OpenAPI mutation tool ... requires _confirm: true`.
- Captain/native mutation no-confirm probes: blocked with `Captain tool ... requires _confirm: true`.
- Representative confirmed mutations worked on isolated DEV fixtures with run markers `mcp-e2e-*` / `mcp-real-*`: contact, conversation, private note, label, assignee, notification, message, canned response, deal, task, scheduling resource/service/contact/holiday/workday/time-off, CRM/custom attributes, custom filter, integration hook.
- No observed confirmation bypass, secret/token leak, cross-account data leak, or PROD mutation.

## Cleanup proof

- MCP cleanup succeeded for normal scheduling/resource/team/custom-field/label/contact seed path in full audit: `10/10 pass`.
- Real-case cleanup exposed lifecycle gap: `api__contactdelete` failed when contact had linked conversation/CRM/scheduling/communication artifacts.
- DEV fallback cleanup removed only marker/id audit fixtures. Pre-cleanup marker categories/counts:
  - `contacts`: `4`
  - `messages`: `6`
  - `labels`: `1`
  - `canned_responses`: `2`
  - `custom_filters`: `1`
  - `integration_hooks`: `1`
  - `crm_deals`: `2`
  - `crm_tasks`: `2`
  - `scheduling_resources`: `3`
  - `scheduling_appointments`: `1`
  - `confirmation_requests`: `1`
  - `reminders`: `1` (по cleanup report)
- Final marker inventory after cleanup: `0` categories left.

## Readiness findings

### P0
- None found: no confirmation bypass, no unauthorized PROD write, no secret leakage in captured outputs.

### P1 — fix before calling the MCP surface production-perfect
- **Catalog/resources flakiness:** one full run hit `26s` hard timeouts for `tools/list`, `tools/catalog`, `openapi/tools`; refresh later was fast. Add bounded/cached catalog generation + regression budget.
- **Knowledge path latency:** `search_documentation` and `faq_lookup` repeatedly took ~`13.4s` and returned empty/lexical results. Needs bounded semantic/RAG timeout, cache/fallback, and structured degraded status.
- **Bad error contracts:** `api__get_details_of_a_single_automation_rule` returned `500 Internal Server Error` for missing id; `get_campaign_analytics`, scheduling resource schedule/availability, and one `request_confirmation` context returned raw `ActiveRecord::RecordNotFound` style errors. External agents need structured `not_found/not_configured` JSON. **Remediation pass 1: partially fixed** for MCP Captain/OpenAPI not-found normalization and automation-rule missing-id `404`.
- **Exposed inactive tools:** `search_linear_issues`, `cancel_response`, `update_priority`, `update_contact`, `create_company` are advertised but return “not active for this workspace”. Prefer hiding by policy or returning machine-readable `not_active` with setup reason. **Remediation pass 1: call response now returns machine-readable `not_active`; hiding/metadata still pending.**
- **Lifecycle cleanup gap:** `api__contactdelete` is not safe as a generic cleanup/delete when contact has linked conversation/CRM/scheduling artifacts. Need explicit archive/delete lifecycle tools or dry-run dependency report.
- **Confirmation chaining gap:** `request_confirmation` output is correctly redacted for token/URL secrecy, but it can hide `confirmation_request_id`; external agents cannot safely call `resolve_confirmation` without DB-side help.

## Remediation pass 1 — 2026-06-11

Scope: narrow P1 MCP error-contract cleanup only; PROD not touched; unrelated dirty tree left untouched.

Changed files:
- `enterprise/lib/onelink/mcp/captain_tool_adapter.rb`
- `enterprise/lib/onelink/mcp/openapi_catalog.rb`
- `app/controllers/api/v1/accounts/automation_rules_controller.rb`
- `spec/enterprise/lib/onelink/mcp/captain_tool_adapter_spec.rb`
- `spec/enterprise/lib/onelink/mcp/openapi_catalog_spec.rb`
- `spec/enterprise/controllers/api/v1/accounts/mcp_controller_spec.rb`
- `spec/controllers/api/v1/accounts/automation_rules_controller_spec.rb`

Implemented:
- Captain MCP inactive runtime tools now return `structuredContent.code = not_active` instead of plain-text-only error.
- Captain/OpenAPI MCP adapter rescues `ActiveRecord::RecordNotFound` as structured `not_found` without exposing raw class/model internals.
- OpenAPI fallback now includes parsed JSON error bodies in `structuredContent` for non-2xx Rails responses.
- Automation rule `show/update/destroy/clone` lookup now uses account-scoped `find` with `id || automation_rule_id`, so missing automation rule returns handled `404` instead of rendering nil into `500`.
- MCP request regression added for `api__get_details_of_a_single_automation_rule` missing id: structured error, no `Internal Server Error`, no `AutomationRule` leak.

Verification:
- RED observed first: targeted specs failed on missing `structuredContent`, raw not-found leak path, and automation-rule `500`.
- GREEN: `bundle exec rspec spec/enterprise/lib/onelink/mcp/captain_tool_adapter_spec.rb spec/enterprise/lib/onelink/mcp/openapi_catalog_spec.rb spec/enterprise/controllers/api/v1/accounts/mcp_controller_spec.rb spec/controllers/api/v1/accounts/automation_rules_controller_spec.rb` → `75 examples, 0 failures`.
- Syntax: `ruby -c` on changed Ruby source/spec files → `Syntax OK`.
- Targeted RuboCop: blocked by existing MCP class/metrics/style baseline (`ClassLength`, `MethodLength`, `Style/ClassAndModuleChildren`, etc.); no autocorrect applied.

Remaining P1 after pass 1:
- catalog/resource generation flakiness and timeout budget;
- knowledge path total budget/structured degraded mode;
- contact delete/dependency lifecycle report;
- confirmation chaining id redaction policy;
- optional hiding/metadata for inactive tools in `tools/list`.

### P2 — quality/agent UX improvements
- OpenAPI fallback names are functional but less native for agents (`api__contactcreate`, `api__newconversation`, etc.). Add native aliases/wrappers for common business flows.
- Normalize validation errors like date range / duplicate webhook URL into stable `{code, message, field}` JSON.
- Add more enums/domain hints in schemas for IDs/statuses; catalog tools exist, but fallback OpenAPI schemas are still generated/API-shaped.

## Per-tool assessment

- Per-tool CSV: `/root/crafty/onelink/chatwoot/.hermes/reports/2026-06-11_084406-mcp-full-tool-audit-per-tool.csv`
- Grade counts: A `88`, B `148`, C `11`, D `1`, BLOCKER `0`.
- Interpretation: `A` native/clear/stable; `B` works but generated/OpenAPI-shaped; `C` works or is safely blocked but has UX/error/lifecycle/latency gap; `D` bad error/runtime shape; `BLOCKER` would mean bypass/secret/cross-account/unclean mutation.

## DEV health after audit

- `onelink-chatwoot-dev.service`: `active`
- `https://dev.one-link.kz/`: `200`
- `https://dev.one-link.kz/app/login`: `200`
- unauth `GET /api/v1/accounts/530/mcp`: `401` expected

## Artifacts

- Run dir: `/root/crafty/onelink/chatwoot/tmp/mcp_audit/20260611T061722Z`
- Main full audit: `/root/crafty/onelink/chatwoot/tmp/mcp_audit/20260611T061722Z/full_audit_results.json` / `/root/crafty/onelink/chatwoot/tmp/mcp_audit/20260611T061722Z/full_audit_report.md`
- Missing-tools follow-up: `/root/crafty/onelink/chatwoot/tmp/mcp_audit/20260611T061722Z/remaining_tools_results.json` / `/root/crafty/onelink/chatwoot/tmp/mcp_audit/20260611T061722Z/remaining_tools_report.md`
- Real-case audit: `/root/crafty/onelink/chatwoot/tmp/mcp_audit/20260611T061722Z/real_case_results.json` / `/root/crafty/onelink/chatwoot/tmp/mcp_audit/20260611T061722Z/real_case_report.md`
- Inventory: `/root/crafty/onelink/chatwoot/tmp/mcp_audit/20260611T061722Z/inventory.json` / `/root/crafty/onelink/chatwoot/tmp/mcp_audit/20260611T061722Z/inventory.csv`
- Combined runtime CSV: `/root/crafty/onelink/chatwoot/tmp/mcp_audit/20260611T061722Z/runtime_summary.csv`
- Cleanup before/after: `/root/crafty/onelink/chatwoot/tmp/mcp_audit/20260611T061722Z/dev_marker_inventory_before.json` / `/root/crafty/onelink/chatwoot/tmp/mcp_audit/20260611T061722Z/dev_marker_inventory_after.json`
- Hard cleanup reports: `/root/crafty/onelink/chatwoot/tmp/mcp_audit/20260611T061722Z/dev_hard_cleanup_report.json` / `/root/crafty/onelink/chatwoot/tmp/mcp_audit/20260611T061722Z/dev_hard_cleanup_sql_report.json`

## Bottom line

MCP account 530 is usable by external agents for broad DEV workflows: discovery, read paths, confirmation-gated mutations, support/CRM/scheduling/outbound flows all work. It is **not yet perfect enterprise-grade** because of several error-contract, lifecycle, and performance gaps above. The highest-value next fix is to normalize not-found/not-active errors and harden/cache catalog + knowledge paths, then rerun the same harness.
