# OneLink Native AI Full Stack Implementation Plan

> **For Hermes:** This is a discussion-first implementation plan. Do not implement an etapa until the user approves that etapa's scope. Use `subagent-driven-development` only after the etapa is approved.

**Goal:** Build a native, enterprise-grade OneLink AI stack around Captain/Copilot/AI Voice that is reliable, fast, resource-efficient, case-driven, observable, evaluated, and scalable.

**Architecture:** OneLink remains the primary product framework/runtime. `ruby_llm` is the first source for core LLM capabilities. Secondary libraries are adopted selectively only where they provide richer or higher-quality functionality, and are adapted into OneLink-native contracts instead of replacing Captain orchestration, account routing, tool policy, confirmations, audit, or UI.

**Tech Stack:** Rails/Chatwoot/OneLink, Captain runtime, RubyLLM, ruby_llm-schema, ruby_llm-mcp, ruby_llm-tribunal, OneLink native tools, OpenTelemetry/GenAI semantic attributes, persisted AI event summaries, Sidekiq/Redis/Postgres, Vue dashboard.

---

## Non-Negotiable Rules

1. **Every etapa must leave the product working.**
   - No big-bang rewrite.
   - No partial runtime replacement.
   - Feature/env flags for risky changes.
   - Rollback path documented before deploy.

2. **Discuss before implementation.**
   - For each etapa we maintain:
     - `Take`
     - `Do not take`
     - `Adapt into OneLink`
     - `Open questions`
     - `Acceptance gate`
   - Implementation starts only after the etapa is approved.

3. **OneLink is the framework.**
   - Captain/Copilot/AI Voice runtime stays product-native.
   - External libraries are inputs/reference layers, not the product architecture.

4. **Fast and resource-light by design.**
   - No raw content capture by default.
   - No excessive DB writes per token/chunk.
   - No unbounded prompt/tool payloads.
   - No repeated catalog/model recomputation in hot paths.
   - Metrics must include latency, token/cost, queue time, DB writes, and error rate.

5. **Enterprise-grade safety.**
   - Account-scoped routing and credentials.
   - Permission-aware tools.
   - Confirmation gates for high-risk/non-idempotent actions.
   - Redaction for traces/logs/tool outputs.
   - Retention policy for AI event data.

6. **Case-driven completeness.**
   - Every major project case must map to:
     - runtime flow;
     - tools;
     - prompts/rules/scenarios;
     - eval cases;
     - RSpec/request specs;
     - observability events;
     - admin/operator UI evidence.

---

## Source Hierarchy

### Primary

- **OneLink product runtime**
  - Captain/Copilot/AI Voice orchestration
  - account/workspace model
  - conversations/inboxes/contacts/CRM/scheduling/touches/campaigns
  - product UI
  - permission and confirmation policy

- **`ruby_llm` core**
  - chat lifecycle
  - providers/models/context
  - tools
  - content/attachments
  - embeddings/transcription surfaces
  - model metadata/pricing

### Secondary / Selective Adoption

- **`ruby_llm-schema`**
  - strict structured output contracts
  - schema generation/validation

- **`ruby_llm-mcp`**
  - MCP server/client semantics
  - OAuth/PKCE patterns
  - tool/resource/task concepts

- **`ruby_llm-tribunal`**
  - datasets
  - judges
  - red-team/eval runners

- **`opentelemetry-instrumentation-ruby_llm`**
  - `gen_ai.*` OpenTelemetry semantic attributes
  - content capture off by default
  - chat/tool/embedding span shape

- **`ruby_llm-monitoring`**
  - persisted summarized events
  - cost/latency/error/throughput metrics
  - alert rules/channel model

Reference folder already created: `example/rubyllm_library/`.

---

## Global Acceptance Gates

Every etapa must pass these before it is called done:

- **Working product:** existing Captain text flow still works.
- **No secret/raw data leak:** no tokens, credentials, raw private tool payloads, or full customer prompts persisted/exported by default.
- **Targeted tests:** relevant RSpec/request/frontend tests pass.
- **Syntax/lint:** Ruby syntax and targeted JS lint where applicable.
- **Performance proof:** no obvious hot-path regression; record expected additional DB writes/events per run.
- **Rollback:** flag/config or small revert path exists.
- **Docs/plan updated:** `Take/Do not take/Adapt/Acceptance` section updated based on actual findings.

---

## Etapa 0 — Baseline Inventory / Read-Only Audit

**Objective:** Freeze the current truth before changing runtime.

**No code changes except this plan and optional audit notes.**

### Take

- Current OneLink runtime facts from code, not assumptions.
- Current `example/rubyllm_library` guidance.
- Current dirty tree awareness to avoid overwriting teammate/session work.

### Do not take

- Do not install gems.
- Do not mount monitoring UI.
- Do not modify Captain runtime.
- Do not run mutating prod/dev commands.

### Inspect

- `Gemfile`
- `lib/llm/**/*`
- `lib/integrations/llm_instrumentation*`
- `lib/opentelemetry_config.rb`
- `enterprise/lib/captain/runtime/**/*`
- `enterprise/app/services/captain/**/*`
- `lib/llm/structured_output_policy.rb`
- `app/models/llm/**/*`
- `db/schema.rb`
- `config/llm.yml`
- `config/agents/tools.yml`
- `example/rubyllm_library/**/*`

### Output

Create/update an audit section with:

- current runtime surfaces;
- current event sources;
- current DB persistence;
- current token/cost capture;
- current schema retry behavior;
- current tool trace behavior;
- current gaps;
- first safe implementation slice.

### Verification

- Read-only commands only.
- `git status --short --branch --untracked-files=all` captured before and after.

### Acceptance Gate

User approves the etapa 1 scope after seeing actual gaps.

---

## Etapa 1 — Normalized Event Contract V1

**Objective:** Define one OneLink-native AI event vocabulary without replacing existing runtime.

### Take

From `opentelemetry-instrumentation-ruby_llm`:

- `gen_ai.operation.name`
- `gen_ai.provider.name`
- `gen_ai.request.model`
- `gen_ai.response.model`
- `gen_ai.usage.input_tokens`
- `gen_ai.usage.output_tokens`
- `gen_ai.tool.name`
- `gen_ai.tool.call.id`
- `error.type`

From OneLink:

- `account_id`
- `assistant_id`
- `conversation_id`
- `message_id`
- `inbox_id`
- `copilot_thread_id`
- `feature`
- `run_id`
- `schema_name`
- `tool_id`
- `risk_level`
- `confirmation_required`

### Do not take

- No generic monkey-patch as the main source until duplicate span risk is proven safe.
- No raw prompt/content capture by default.
- No event per streaming token.

### Adapt into OneLink

Candidate event names:

- `llm.run.started`
- `llm.chat.complete`
- `llm.chat.failed`
- `llm.tool.started`
- `llm.tool.finished`
- `llm.tool.failed`
- `llm.schema.invalid`
- `llm.retry`
- `llm.safety.blocked`
- `llm.confirmation.required`
- `llm.agent.handoff`
- `llm.embedding.complete`
- `llm.transcription.complete`
- `llm.moderation.complete`

### Likely Files

- `lib/llm/event_bus.rb`
- `lib/integrations/llm_instrumentation.rb`
- `enterprise/lib/captain/runtime/instrumentation.rb`
- specs near current LLM/Captain instrumentation specs

### Performance Rules

- Event payload must be small.
- Redaction happens before publish/export.
- Event contract supports sampling later.

### Tests

- Unit specs for event payload normalization.
- Regression spec proving content is not captured by default.
- Spec proving product metadata is included when available.

### Acceptance Gate

Existing runtime behavior unchanged; new event contract emits safe metadata in test/dev.

---

## Etapa 2 — Safe Persisted AI Run Summary

**Objective:** Persist operational summaries for RCA, metrics, and enterprise reporting without storing raw prompts.

### Take

From `ruby_llm-monitoring`:

- persisted event summary concept;
- cost calculation from model pricing;
- generated/queryable fields for provider/model/tokens/errors;
- retention requirement;
- alert-rule model idea.

### Do not take

- Do not mount `RubyLLM::Monitoring::Engine` as product UI.
- Do not expose `/monitoring` without auth.
- Do not persist raw `chat` or `response` objects.
- Do not keep data indefinitely without retention policy.

### Adapt into OneLink

Persist a OneLink-native summary shaped for enterprise operations:

- `run_id`
- `trace_id`
- `account_id`
- `assistant_id`
- `conversation_id`
- `message_id`
- `feature`
- `provider`
- `model`
- `schema_name`
- `status`
- `duration_ms`
- `queue_wait_ms` if available
- `input_tokens`
- `output_tokens`
- `thinking_tokens`
- `estimated_cost`
- `tool_calls_count`
- `schema_invalid_count`
- `retry_count`
- `error_class`
- `error_code`
- sanitized `metadata`

### Likely Files

- `app/models/llm/*`
- `db/migrate/*`
- `lib/llm/event_bus.rb`
- `lib/llm/models.rb`
- `spec/models/llm/*`
- `spec/lib/llm/*`

### Performance Rules

- One summary row per run, not unlimited rows per message chunk.
- Optional child events only for tool/schema/debug, bounded count.
- Async persistence if synchronous writes add latency.
- Indexes only for known query patterns.

### Tests

- Summary created for successful run.
- Summary created for failed run.
- Tokens/cost calculated if model pricing exists.
- Missing model pricing degrades to zero/unknown cost, not crash.
- Raw content absent.

### Acceptance Gate

A Captain run can be traced by `run_id` with safe summary and no behavior change.

---

## Etapa 3 — OTel Export Compatibility

**Objective:** Export OneLink AI events/spans in OTel GenAI-compatible shape.

### Take

From `opentelemetry-instrumentation-ruby_llm`:

- span naming;
- `gen_ai.*` attributes;
- content capture flag pattern;
- custom attributes concept.

### Do not take

- No duplicate spans.
- No content capture in production default.
- No tool args/result export without redaction/truncation.

### Adapt into OneLink

- Keep OneLink event bus as source of truth.
- OTel exporter subscribes/adapts from OneLink events.
- Add provider/model/token/tool/schema attrs.
- Add product attrs under a clear namespace, e.g. `one_link.*`.

### Likely Files

- `lib/opentelemetry_config.rb`
- `lib/integrations/llm_instrumentation.rb`
- `config/initializers/*otel*` if present
- tests for instrumentation/export adapters

### Performance Rules

- Export should never block user response path indefinitely.
- OTLP errors should not break Captain.
- Support sampling/config toggle.

### Acceptance Gate

OTel metadata export works in dev/test; disabled export does not affect runtime.

---

## Etapa 4 — Runtime Health / Alerts V1

**Objective:** Turn summaries into actionable operations signals.

### Take

From `ruby_llm-monitoring`:

- throughput/cost/latency/error metrics;
- alert rule concept;
- channel registry idea.

### Do not take

- Do not build a separate generic monitoring UI.
- Do not spam alerts.
- Do not alert on raw noisy events without cooldown.

### Adapt into OneLink

Initial alerts:

- provider error spike;
- schema invalid spike;
- tool failure spike;
- cost daily/monthly threshold;
- `captain_runtime` queue backlog;
- embeddings unavailable;
- AI Voice latency threshold.

### Likely Files

- `app/models/llm/*`
- `app/services/llm/*metrics*`
- `app/jobs/llm/*`
- OneLink notification/Slack/email integration points

### Performance Rules

- Metrics queries must use indexed fields/rollups.
- Avoid scanning huge JSON payloads in hot dashboards.
- Retention/aggregation strategy required before prod scale.

### Acceptance Gate

At least one safe alert rule and one metrics query work on persisted summaries.

---

## Etapa 5 — Structured Output Hardening

**Objective:** Make structured output not just valid JSON, but semantically useful and recoverable.

### Take

From `ruby_llm-schema`:

- strict JSON schema;
- schema validation;
- schema DSL/contracts.

From OneLink current code:

- `Llm::StructuredOutputPolicy` retry path.

### Do not take

- Do not assume valid schema means good answer.
- Do not retry mutating tool calls blindly.
- Do not hide schema failures from trace/evals.

### Adapt into OneLink

Add semantic validators:

- blank `response` failure;
- tool-needed-but-not-called failure where detectable;
- invalid handoff output;
- invalid artifact/tool ids;
- missing required user-facing message after non-mutating flow.

### Likely Files

- `lib/llm/structured_output_policy.rb`
- `enterprise/app/services/captain/**/*runner*`
- `enterprise/lib/captain/runtime/**/*`
- `spec/lib/llm/structured_output_policy_spec.rb`
- Captain runtime specs

### Performance Rules

- Max one safe retry by default.
- No retry after mutating tools unless idempotency key confirms safe.
- Schema validation should reuse compiled schema where possible if hot.

### Acceptance Gate

Blank/invalid semantic output is caught, traced, and recovered/fails safely.

---

## Etapa 6 — Tool Contract Modernization

**Objective:** Make tools reliable for LLM use and predictable for enterprise operations.

### Take

From OneLink native tool modernization rules:

- structured payloads;
- object/array params;
- `limit`, `filters`, `total_count`;
- domain payload builders;
- Assistant/Copilot/public symmetry where appropriate.

### Do not take

- No text dumps for search/read tools.
- No JSON-string params where object params are possible.
- No high-risk mutation without confirmation policy.
- No prompt-visible tool that runtime blocks for hidden mismatch unless explicitly documented.

### Adapt into OneLink

Prioritize tools by product cases:

1. conversation support;
2. CRM deals/tasks/contacts;
3. scheduling/appointments;
4. touches/reminders/follow-up;
5. campaigns/templates;
6. files/artifacts;
7. integrations/MCP/custom HTTP tools;
8. admin/user/team tools.

### Likely Files

- `enterprise/lib/captain/tool_registry.rb`
- `enterprise/lib/captain/tools/**/*`
- `enterprise/app/services/captain/tools/**/*`
- `enterprise/lib/captain/tools/operations/**/*`
- `spec/enterprise/lib/captain/**/*`
- `spec/enterprise/services/captain/tools/**/*`

### Performance Rules

- Search tools must default to bounded `limit`.
- Avoid loading full associations in tool payloads.
- Payload builders must be compact and AI-safe.
- Tool timeouts and error normalization required.

### Acceptance Gate

Each modernized tool has matching specs, structured outputs, and no regressions in existing flow.

---

## Etapa 7 — Confirmation / Safety Layer

**Objective:** Allow more powerful tools without enterprise risk.

### Take

From OneLink patterns:

- confirmation gates in registry and runtime;
- high-risk metadata;
- assistant-scope policy;
- `ConfirmationRequest` pattern where needed.

### Do not take

- No UI-only confirmation without runtime enforcement.
- No direct execution bypass for high-risk tools.
- No customer-agent access to internal/admin-only tools.

### Adapt into OneLink

Confirm before:

- sending external messages when not obviously user-approved;
- creating/updating/deleting CRM entities in high-risk contexts;
- merging contacts;
- launching/retrying campaigns;
- user/team/role changes;
- payment/invoice/refund/POS actions;
- custom HTTP tools marked high-risk.

### Likely Files

- `enterprise/lib/captain/tool_registry.rb`
- `enterprise/lib/captain/tool_policy.rb`
- `enterprise/lib/captain/tools/base_tool.rb`
- confirmation domain files if already present / new domain files if approved
- specs for registry + runtime enforcement

### Performance Rules

- Confirmation check must be cheap metadata lookup.
- Pending confirmation state must be indexed and bounded.

### Acceptance Gate

Representative high-risk tool blocks with `confirmation_required`; read-only tool is not over-gated.

---

## Etapa 8 — Model Routing / Specialized Surfaces

**Objective:** One consistent, account-aware resolver for all AI surfaces.

### Take

From `ruby_llm`:

- provider/model registry;
- context;
- model metadata/pricing/capabilities.

From OneLink OpenRouter lessons:

- no silent fallback;
- capability-safe surface routing;
- specialized models for audio/moderation/embeddings/image.

### Do not take

- Do not assume OpenRouter chat key covers embeddings/audio/moderation.
- Do not show incompatible models for Captain tools/structured output.
- Do not recompute model catalogs repeatedly in request hot paths.

### Adapt into OneLink

Surfaces:

- Captain assistant chat;
- Copilot;
- image recognition;
- audio/transcription;
- moderation/safety;
- embeddings/help-center/FAQ;
- editor/label suggestions;
- eval judges.

### Likely Files

- `lib/llm/config.rb`
- `lib/llm/models.rb`
- `lib/llm/chat_client.rb`
- `config/llm.yml`
- `app/controllers/api/v1/accounts/captain/preferences_controller.rb`
- Captain settings UI

### Performance Rules

- Request-level memoization for provider/model catalog.
- Cache model capability lists.
- Fail fast for incompatible surfaces.

### Acceptance Gate

Each surface resolves provider/model explicitly with no hidden fallback and no preferences timeout.

---

## Etapa 9 — Knowledge / RAG / Documents

**Objective:** Make Captain knowledge reliable, traceable, and scalable.

### Take

From OneLink patterns:

- source text separate from bounded content;
- FAQ generation as document-level behavior;
- embeddings status/backfill;
- lexical fallback only as degraded mode;
- artifact IDs for file delivery.

### Do not take

- No prompt stuffing with huge docs.
- No silent embeddings failure.
- No raw signed blob IDs through LLM text.

### Adapt into OneLink

- Store source text/chunks/facts separately.
- Track embedding state.
- Add trace: which facts/docs were used and why.
- Add reindex/backfill UI/ops flow.
- Send files via scoped artifact IDs and existing attachment pipeline.

### Performance Rules

- Chunk/search bounded.
- Embeddings async and backfillable.
- Cache frequent retrieval where safe.

### Acceptance Gate

Knowledge answer shows traceable retrieval and does not degrade into huge prompt cost.

---

## Etapa 10 — AI Voice Parity With Captain

**Objective:** AI Voice uses the same Captain brain while keeping transport/dialogue separate.

### Take

From OneLink AI Voice skills:

- Captain assistant instructions/config;
- tools/rules/scenarios;
- post-call memory/FAQ features;
- DialogueDirector ideas;
- tool progress/fillers.

### Do not take

- No detached voice-only prompt stack.
- No long silence during tools.
- No voice path that ignores Captain rules/tools.

### Adapt into OneLink

- Shared Captain runtime state.
- Voice transport handles realtime audio/turn taking.
- Tool calls produce speech-safe progress updates.
- Post-call transcript features feed Captain memory/FAQ.

### Performance Rules

- Voice requires strict latency budget.
- Tool-heavy voice flows need fillers/progress.
- Avoid large prompt rebuilds per turn.
- Preload/cache assistant config where safe.

### Acceptance Gate

Voice and text Captain produce consistent tool/rule behavior, with acceptable latency and no silent waits.

---

## Etapa 11 — Eval System / Quality Gates

**Objective:** Make quality measurable and regression-safe.

### Take

From `ruby_llm-tribunal`:

- datasets;
- judges;
- red-team suites;
- eval runner concept.

### Do not take

- Do not replace RSpec with evals.
- Do not run expensive live evals on every small change.
- Do not use evals without deterministic fixtures where possible.

### Adapt into OneLink

Eval packs:

- brand voice;
- support correctness;
- CRM tool choice;
- scheduling correctness;
- touches/follow-up;
- WhatsApp template policy;
- knowledge/RAG correctness;
- confirmation safety;
- AI Voice transcript behavior;
- red-team/prompt injection.

### Performance Rules

- Deterministic default CI pack.
- Live/provider pack manually or scheduled.
- Store only summarized eval results.

### Acceptance Gate

Every major bugfix/feature can add a case, and CI has a practical deterministic gate.

---

## Etapa 12 — Admin / Operator Observability UI

**Objective:** Make AI behavior understandable without engineers reading logs.

### Take

From `ruby_llm-monitoring`:

- dashboard metrics concept.

From OneLink:

- product-native UI in Captain/admin surfaces.
- human-readable tool trace panels.

### Do not take

- No separate generic monitoring engine as final UX.
- No escaped/raw JSON debug envelopes for operators.
- No sensitive content by default.

### Adapt into OneLink

Views:

- AI run trace by conversation/message;
- tool timeline;
- model/provider/tokens/cost;
- latency and queue wait;
- schema/retry/fallback reasons;
- eval dashboard;
- alerts/health;
- model/surface config health.

### Performance Rules

- Dashboard queries must use summaries/rollups.
- Avoid loading raw payloads by default.
- Pagination everywhere.

### Acceptance Gate

Operator/admin can answer “why did Captain do this?” from UI for a representative run.

---

## Etapa 13 — Enterprise Scale Hardening

**Objective:** Ensure the stack survives high-volume enterprise use.

### Take

- Account/workspace isolation.
- Rate limits and quotas.
- Retention/archival.
- Queue isolation.
- Cost budgets.
- Backpressure.
- Idempotency for mutations.

### Do not take

- No unbounded Sidekiq queues without alerts.
- No unlimited tool output size.
- No per-account noisy neighbor behavior.
- No global credentials when account credentials are required.

### Adapt into OneLink

- Per-account limits.
- Per-surface provider policy.
- Queue capacity planning.
- Tool timeout budgets.
- Retry strategy by idempotency class.
- Data retention for AI events/evals/traces.

### Performance Rules

Track and cap:

- median/p95/p99 latency;
- DB writes per run;
- prompt tokens per case;
- tool payload bytes;
- Sidekiq queue wait;
- memory growth in long-running workers.

### Acceptance Gate

Load/canary proof for representative enterprise flows with no resource spike.

---

## Case Coverage Matrix To Fill During Planning

Each project case must be mapped before final “full stack complete” claim.

| Case | Runtime | Tools | Schema | Safety | Eval | Trace | UI | Perf Budget | Status |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Customer support reply | TBD | TBD | TBD | TBD | TBD | TBD | TBD | TBD | TBD |
| CRM deal create/update/search | TBD | TBD | TBD | TBD | TBD | TBD | TBD | TBD | TBD |
| Scheduling appointment | TBD | TBD | TBD | TBD | TBD | TBD | TBD | TBD | TBD |
| Touch/reminder/follow-up | TBD | TBD | TBD | TBD | TBD | TBD | TBD | TBD | TBD |
| Campaign/template send | TBD | TBD | TBD | TBD | TBD | TBD | TBD | TBD | TBD |
| Knowledge/RAG answer | TBD | TBD | TBD | TBD | TBD | TBD | TBD | TBD | TBD |
| File/artifact send | TBD | TBD | TBD | TBD | TBD | TBD | TBD | TBD | TBD |
| MCP/custom HTTP tool | TBD | TBD | TBD | TBD | TBD | TBD | TBD | TBD | TBD |
| Internal assistant/admin operation | TBD | TBD | TBD | TBD | TBD | TBD | TBD | TBD | TBD |
| AI Voice inbound call | TBD | TBD | TBD | TBD | TBD | TBD | TBD | TBD | TBD |
| AI Voice post-call memory/FAQ | TBD | TBD | TBD | TBD | TBD | TBD | TBD | TBD | TBD |
| Provider/model fallback failure | TBD | TBD | TBD | TBD | TBD | TBD | TBD | TBD | TBD |
| Prompt injection / unsafe request | TBD | TBD | TBD | TBD | TBD | TBD | TBD | TBD | TBD |

---

## Performance Budgets To Define Per Case

Before implementation of each case, fill target budgets:

- **Text reply no tools:** target p95 TBD.
- **Text reply 1 tool:** target p95 TBD.
- **RAG answer:** target p95 TBD.
- **Tool-heavy CRM/scheduling:** target p95 TBD.
- **AI Voice first response:** target p95 TBD.
- **AI Voice tool wait:** must use filler/progress if over TBD ms.
- **DB writes per run:** max TBD.
- **Trace/event payload size:** max TBD.
- **Prompt tokens per case:** max TBD.
- **Cost per case:** target/alert TBD.

---

## Suggested First Discussion

Start with **Etapa 0 — Baseline Inventory / Read-Only Audit**.

Decision points for discussion:

1. Which production/dev environment is source of truth for runtime proof?
2. Should AI event summaries use current `llm_events` or a new normalized table?
3. Which first user-facing cases must be in the coverage matrix before any coding?
4. What latency budgets are acceptable for text and AI Voice?
5. Which observability data is allowed in production by default?

---

## Current Plan Status

- Plan file created.
- No implementation started.
- Next approved action should be read-only audit only.

## Pinned First Step

**Start here:** Etapa 0 — Baseline Inventory / Read-Only Audit.

Scope:

- read-only only;
- no code/runtime changes;
- no gem installs;
- no service restarts;
- no production mutations;
- inspect current OneLink AI runtime, instrumentation, `llm_events`, structured output, tool traces, model routing, evals, and performance/resource hot paths;
- produce a short audit: `already works / gaps / first safe implementation slice / risks / tests`.

Success criteria:

- exact current-state map exists;
- first implementation slice is small and independently deployable;
- user approves Etapa 1 before any code changes.

---

## Etapa 0 Audit Snapshot — 2026-05-22

Status: **Etapa 0 completed as a read-only/code-inspection audit; runtime product code was not changed in this audit update.**

### Current dirty-tree boundary

The worktree is broad and must be stabilized before new runtime slices:

- **Captain evals / Etapa 11:** 27 dirty/untracked paths around `/captain/evaluations`, `Llm::EvalRun`, `Llm::Evals::RunJob`, `Llm::Evals::RunRequest`, Tribunal dataset/red-team, and eval specs.
- **LLM routing/runtime:** 7 dirty/untracked paths around `config/llm.yml`, `lib/llm/models.rb`, Captain preferences, OpenAI message builder, and image recognition service/specs.
- **Husky tooling:** 2 hook files; tooling-only, split from product commits.
- **SMM/Postiz:** 20 untracked product paths; separate module, not part of this native AI full-stack plan.
- **Reference audit docs:** `example/rubyllm_library/**/*` exists as secondary-library reference material.

### Already works / exists now

- **Etapa 1 base:** `lib/llm/event_bus.rb` publishes `llm.*` through `ActiveSupport::Notifications` and carries request/trace/session/account/assistant/conversation/copilot/feature/runtime context.
- **Etapa 2 base:** `llm_events`, `llm_event_annotations`, and dirty-tree `llm_eval_runs` exist. `LlmEvent` has indexed query fields and `Llm::Monitoring::EventRecorder` persists summarized tokens/cost/provider/model/status/schema/tool/error fields.
- **Etapa 3 base:** `lib/integrations/llm_instrumentation*.rb` exists with specs for `gen_ai.*` attrs and content-capture behavior.
- **Etapa 4 base:** monitoring snapshots, alerts, Prometheus exporter, release gate, retention, and events query exist with specs.
- **Etapa 5 base:** `Llm::StructuredOutputPolicy` validates JSON schema, retries once, and publishes `llm.schema.invalid` / `llm.schema.repair_requested` without raw response content.
- **Etapa 6/7 base:** Captain tool registry and many tool specs exist, including CRM/scheduling/document/observability surfaces.
- **Etapa 8 base:** `lib/llm/config.rb`, `lib/llm/models.rb`, `config/llm.yml` define feature model surfaces: editor, assistant, copilot, label suggestion, audio transcription, image recognition, help center search, moderation.
- **Etapa 11 active:** eval UI/API/job/request/model/dataset/red-team work is present in dirty tree and already has safety hardening slices.

### Gaps / inconsistencies to fix before full-stack readiness

1. **Plan/status mismatch:** original plan said no implementation started; current tree already includes Etapa 11 and partial Etapa 8 work.
2. **Dirty tree too broad:** AI/evals, LLM routing, Husky, SMM/Postiz, and reference docs are mixed.
3. **Event contract not normalized:** current code emits `llm.run.start`, `llm.tool.execute`, `llm.tool.progress`, `llm.tool.complete`; plan proposed `started/finished/failed` names. Need canonical names or compatibility aliases.
4. **Summaries incomplete for enterprise RCA:** current events cover duration/tokens/cost/status/error/tool/schema, but need consistent `queue_wait_ms`, `thinking_tokens`, `tool_calls_count`, `schema_invalid_count`, `retry_count`, `error_code`, payload byte budgets, and DB-write budgets.
5. **Raw-content policy needs final proof:** event recorder sanitizes and structured output emits type/size only, but OTel/UI/exporters need final production-default proof.
6. **Structured output is schema-valid, not fully semantic:** still need validators for blank user-facing message, tool-needed-but-not-called, invalid handoff/action ids, invalid artifact/tool ids, and no unsafe retry after mutating tools.
7. **Tool modernization is case-by-case:** every major project case still needs a matrix proving bounded structured outputs, confirmation policy, trace events, evals, UI evidence, and tests.
8. **AI Voice parity remains open:** tool dispatch exists, but shared Captain state, voice-safe fillers/progress, latency budgets, post-call memory/FAQ, and voice eval traces still need full proof.
9. **Eval system needs stabilization:** final path-scoped review, targeted checks, DEV smoke, and commit split before it becomes a quality gate.
10. **SMM/Postiz is out-of-plan noise:** review/test/commit separately or move out before native AI stack work continues.

### First safe implementation order from here

1. **Slice A — Worktree hygiene / split ownership**
   - Freeze current dirty tree.
   - Separate/commit or stash by domain: Husky tooling, Captain evals, LLM routing/image recognition, SMM/Postiz, reference docs.
   - No prod deploy until each slice has targeted checks.

2. **Slice B — Finish Etapa 11 eval foundation**
   - Final review of `/captain/evaluations`, `Llm::EvalRun`, `RunJob`, `RunRequest`, Tribunal runner/config/red-team.
   - Verify request/job/service/model specs, Vitest, ESLint, Ruby syntax/RuboCop `--fail-level E`, and `git diff --check`.
   - DEV smoke: UI route 200, unauth API 401, routes/classes load, `llm_eval_runs` schema present, live flag explicit.

3. **Slice C — Etapa 1/2 event contract hardening**
   - Keep `Llm::EventBus` as source of truth.
   - Define canonical event names + compatibility aliases for existing `run.start/tool.execute` names.
   - Add required metadata policy and no-raw-content tests.
   - Add cheap missing summary fields: `retry_count`, `tool_calls_count`, `error_code`, payload byte size.

4. **Slice D — Etapa 5 semantic structured-output hardening**
   - Add semantic validators around Captain conversation completion schema and safe retry policy.
   - Ensure invalid semantic output is traced/evaluable without blindly retrying mutating tools.

5. **Slice E — Case matrix expansion**
   - Fill project cases one by one: customer support, CRM, scheduling, touches, campaigns/templates, knowledge/RAG, files/artifacts, custom HTTP/MCP, internal admin ops, AI Voice, provider failure, prompt injection.
   - Each case must have runtime path, tools, schema/safety, eval case, trace evidence, UI evidence, perf budget, and tests.

### Provisional performance/resource budgets

Replace with measured DEV/prod values after instrumentation smoke:

- Text reply, no tools: p95 <= 2.5s excluding provider spikes.
- Text reply, 1 bounded tool: p95 <= 5s.
- RAG answer: p95 <= 6s with bounded chunks/facts.
- Tool-heavy CRM/scheduling: p95 <= 8s, with progress/filler if user-visible wait exceeds 2s.
- AI Voice first response: p95 <= 1.2s after final user turn when no tool is needed.
- AI Voice tool wait: filler/progress required if tool wait exceeds 700ms.
- DB writes per normal text run: target <= 3 summary/event writes; no per-token writes.
- Event payload: target <= 8KB persisted payload after redaction; raw prompts/tool secrets forbidden by default.
- Eval live runs: max cases and budget enforced server-side; deterministic CI remains default.

### Next immediate action

Proceed with **Slice A + Slice B** before new feature work: isolate AI/evals from SMM/Postiz, finish Captain eval foundation review/tests, then implement Etapa 1/2 event-contract hardening.

## 2026-05-22 Slice B hardening status

Completed after independent review:

- Blocked repeated live-eval spend:
  - `llm_eval_runs` now has a partial unique index for one active live eval per account.
  - `Llm::Evals::RunRequest` maps unique-index races to `llm_model_eval_already_running`.
  - `Llm::Evals::RunJob` atomically claims only `queued` runs and skips duplicate/terminal executions.
- Tightened spend bounds:
  - live pack cost estimates multiply by live pack count;
  - dataset live-assertion budget uses bounded assertion/case units and still requires env flag + acknowledgement.
- Removed raw result leakage from admin UI/status:
  - `run_status` returns compact run summary only;
  - stored eval results/errors are redacted/truncated via `Llm::EvalRun.sanitize_result`;
  - dataset API/UI show compact summary/report, not raw cases/prompts/outputs;
  - frontend renders `result_summary`, not `evalRun.result` JSON.
- Dataset LLM judge UX now exposes visible budget/max-cases/ack controls and disables run until acknowledged.
- Husky hooks fixed/verified:
  - conditional `.husky/_/husky.sh` sourcing;
  - pre-commit preserves lint-staged/RuboCop non-zero status;
  - deleted/nonexistent Ruby files are skipped;
  - post-RuboCop `git add` is limited to staged Ruby files only;
  - pre-push propagates `bin/validate_push` status.

Verification completed:

```bash
RBENV_ROOT=/root/.rbenv PATH=/root/.rbenv/bin:/root/.rbenv/shims:$PATH DISABLE_SPRING=1 bundle exec rspec spec/controllers/api/v1/accounts/captain/evaluations_controller_spec.rb spec/lib/llm/evals/run_request_spec.rb spec/jobs/llm/evals/run_job_spec.rb spec/lib/llm/evals/tribunal_dataset_runner_spec.rb spec/enterprise/lib/captain/evals/red_team_suite_spec.rb
# 33 examples, 0 failures

pnpm exec eslint app/javascript/dashboard/routes/dashboard/captain/evaluations/Index.vue app/javascript/dashboard/routes/dashboard/captain/evaluations/Index.spec.js app/javascript/dashboard/api/captain/evaluations.js app/javascript/dashboard/api/specs/captainEvaluations.spec.js
pnpm exec vitest --no-watch --no-cache --no-coverage app/javascript/dashboard/routes/dashboard/captain/evaluations/Index.spec.js app/javascript/dashboard/api/specs/captainEvaluations.spec.js
RBENV_ROOT=/root/.rbenv PATH=/root/.rbenv/bin:/root/.rbenv/shims:$PATH bundle exec rubocop --fail-level E <eval files>
# exit 0; style/metrics C offenses remain in eval controller/runner debt

sh -n .husky/pre-commit && sh -n .husky/pre-push
.husky/pre-commit
.husky/pre-push
# both exit 0 in repo
# isolated hook tests proved lint failure, RuboCop failure, and pre-push status propagation;
# partial-staging regression preserved unstaged JS hunk.

git diff --check -- <touched eval/husky files>
```

Next coding slice:

1. Etapa 1/2 event-contract hardening for Captain runtime traces: schema-typed `ui_actions`, trace/event redaction, bounded event payload, deterministic trace fixtures for the first project cases.
2. Move `run_dataset` live/judge execution from synchronous web request into queued `Llm::EvalRun` once live judge mode is product-enabled.
3. Add eval history/cancel/retry/autopoll and real spend accounting before calling Tribunal live judge production-ready.

## 2026-05-22 Etapa 1/2 event-contract hardening status

Completed first safe backend slice after DEV smoke:

- DEV `chatwoot_dev` pending migration `20260522125100` was applied.
- DEV smoke now passes for the combined evals/SMM surface:
  - `/app/accounts/1/captain/evaluations` -> 200
  - `/app/accounts/1/smm` -> 200
  - `/app/accounts/1/smm/calendar` -> 200
  - `/vite-dev/@vite/client` -> 200
  - unauth `/api/v1/accounts/1/captain/evaluations` -> 401
  - unauth `/api/v1/accounts/1/content/channels` -> 401
  - local Postiz `/auth` -> 200
  - Rails runner confirms `development`, DB `chatwoot_dev`, no pending migrations, eval/content routes/classes loaded, `llm_eval_runs` present, `LLM_EVALS_LIVE_ENABLED=true`.
- `Llm::EventBus` now has explicit accepted aliases for proposed lifecycle names while keeping current persisted event names stable:
  - `llm.run.started` -> `llm.run.start`
  - `llm.run.finished` / `llm.run.failed` -> `llm.run.complete`
  - `llm.tool.started` -> `llm.tool.execute`
  - `llm.tool.finished` / `llm.tool.failed` -> `llm.tool.complete`
  - `llm.schema.repair` -> `llm.schema.repair_requested`
- Every published event payload includes `canonical_event_name`; alias calls also include `event_name_alias`.
- `Llm::Monitoring::PayloadSanitizer` now redacts raw prompt/message/input/output/response/content keys by default, keeps token-usage keys available, limits hash fanout, and preserves existing secret redaction/truncation.
- `Llm::Monitoring::EventRecorder` adds compact RCA fields into persisted sanitized payloads without adding hot-path DB columns yet:
  - `payload_bytes`
  - `retry_count`
  - `tool_calls_count`
  - `schema_invalid_count`
  - `error_code`
  - `queue_wait_ms`
  - `thinking_tokens`

Verification completed:

```bash
RBENV_ROOT=/root/.rbenv PATH=/root/.rbenv/bin:/root/.rbenv/shims:$PATH DISABLE_SPRING=1 bundle exec rspec spec/lib/llm/event_bus_spec.rb spec/lib/llm/event_subscriber_spec.rb spec/lib/llm/monitoring/event_recorder_spec.rb spec/lib/llm/monitoring/payload_sanitizer_spec.rb spec/enterprise/lib/captain/runtime/event_bus_callbacks_spec.rb
# 18 examples, 0 failures

RBENV_ROOT=/root/.rbenv PATH=/root/.rbenv/bin:/root/.rbenv/shims:$PATH DISABLE_SPRING=1 bundle exec rspec spec/lib/llm/monitoring/events_query_spec.rb spec/lib/llm/monitoring/metrics_snapshot_spec.rb spec/lib/llm/monitoring/release_gate_spec.rb spec/enterprise/controllers/api/v1/accounts/captain/observability_controller_spec.rb spec/enterprise/services/captain/tools/copilot/account_observability_tools_spec.rb
# 41 examples, 0 failures

RBENV_ROOT=/root/.rbenv PATH=/root/.rbenv/bin:/root/.rbenv/shims:$PATH bundle exec ruby -c lib/llm/event_bus.rb
RBENV_ROOT=/root/.rbenv PATH=/root/.rbenv/bin:/root/.rbenv/shims:$PATH bundle exec ruby -c lib/llm/monitoring/event_recorder.rb
RBENV_ROOT=/root/.rbenv PATH=/root/.rbenv/bin:/root/.rbenv/shims:$PATH bundle exec ruby -c lib/llm/monitoring/payload_sanitizer.rb
# Syntax OK

RBENV_ROOT=/root/.rbenv PATH=/root/.rbenv/bin:/root/.rbenv/shims:$PATH bundle exec rubocop --fail-level E lib/llm/event_bus.rb lib/llm/monitoring/event_recorder.rb lib/llm/monitoring/payload_sanitizer.rb spec/lib/llm/event_bus_spec.rb spec/lib/llm/monitoring/event_recorder_spec.rb spec/lib/llm/monitoring/payload_sanitizer_spec.rb
# exit 0; existing C-level style/metrics offenses remain in touched legacy files

git diff --check
# clean
```

Next coding slice:

1. Extend deterministic trace fixtures/UI evidence for the first project cases.
2. Promote any RCA fields that prove query-critical from payload-only to indexed DB columns/rollups.
3. Start Etapa 5 semantic structured-output hardening: blank response, invalid handoff/action/artifact ids, and no unsafe retry after mutating tools.
