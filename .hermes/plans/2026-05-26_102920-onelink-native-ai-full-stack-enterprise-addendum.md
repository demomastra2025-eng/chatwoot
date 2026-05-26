# OneLink Native AI Full Stack Enterprise Addendum Plan

> **For Hermes:** This is a follow-up plan to execute **only after** the primary plan is completed or explicitly paused by the user. Do not implement any task here without a fresh user approval for that task. Use `subagent-driven-development` for implementation and independent review when execution begins.

**Primary plan:** `.hermes/plans/2026-05-22_110801-onelink-native-ai-full-stack.md`

**Goal:** Close the remaining enterprise/product gaps after the primary native AI stack plan lands, so OneLink has a complete, native, fast, observable, safe, and scalable AI platform across Captain, Copilot, AI Voice, Knowledge/RAG, tools, evals, integrations, and operator UI.

**Architecture:** OneLink remains the product framework and runtime. Ruby AI ecosystem libraries are capability/reference sources, not replacement runtimes. Every external idea must be adapted into OneLink-native contracts: account scope, permissions, confirmations, redaction, audit, evals, observability, product UI, Sidekiq/Postgres/Redis operations, and deployment gates.

**Tech Stack:** Rails/Chatwoot/OneLink, Captain runtime, Copilot, AI Voice, RubyLLM, ruby_llm-schema, ruby_llm-mcp, ruby_llm-tribunal, ruby_llm-monitoring concepts, OpenTelemetry GenAI conventions, Sidekiq, Redis, Postgres/pgvector, Vue dashboard, RSpec/Vitest/ESLint/RuboCop.

---

## Why this addendum exists

The primary plan is strong and native, but it is intentionally incremental. It already covers much of the foundation:

- event contract and persisted AI summaries;
- OTel-compatible tracing;
- runtime health/alerts;
- structured output hardening;
- tool contract modernization;
- confirmation and safety layers;
- account-aware model routing;
- Knowledge/RAG chunks, embeddings, traces, and reindex flow;
- eval foundation;
- Captain observability API/UI direction.

The remaining risk is not that the direction is wrong. The risk is claiming “complete enterprise AI stack” before every important product case has proof across:

- runtime flow;
- tools;
- schema/structured output;
- safety/permissions/confirmation;
- eval case;
- trace/event evidence;
- operator/admin UI evidence;
- performance budget;
- live/dev/prod smoke path.

This addendum is the second-stage plan to close those gaps after the primary plan is finished.

---

## Non-negotiable rules

1. **Do not replace OneLink with external demos.**
   - `ruby_llm`, `ruby_llm-schema`, `ruby_llm-mcp`, `ruby_llm-tribunal`, `ruby_llm-monitoring`, and `ai-agents` are reference/capability sources.
   - Captain/Copilot/AI Voice, account routing, tools, audit, and UI remain OneLink-native.

2. **Case-driven completion only.**
   - No feature is “done” until at least one representative product case proves runtime, safety, eval, trace, UI, and performance.

3. **No raw customer content by default.**
   - No prompts, tool secrets, raw provider responses, full transcripts, or private payloads are persisted/exported unless an explicit admin setting enables safe capture with retention.

4. **Fast and resource-light by proof, not intent.**
   - Every case must record p50/p95/p99 latency, queue wait, DB writes/run, event payload bytes, tokens, estimated cost, and fallback/error rate.

5. **Enterprise safety wins over convenience.**
   - High-risk, custom, admin, external HTTP/MCP, money/payment, outbound messaging, and destructive tools require explicit policy and confirmation behavior.

6. **Every stage leaves product working.**
   - Small slices, targeted tests, path-limited commits, no big-bang rewrite.

---

## Completion prerequisites from the primary plan

Start this addendum only after the primary plan has one of these states:

1. **Primary plan completed:** Etapa 0–13 are marked complete with tests/smoke evidence.
2. **Primary plan intentionally paused:** user explicitly asks to continue from this addendum before primary Etapa 13 is fully done.
3. **Specific gap escalation:** user explicitly asks to handle one addendum topic because it became blocking.

Before starting any task here, run read-only checks:

```bash
cd /root/crafty/onelink/chatwoot
git status --short --branch --untracked-files=all
git log --oneline --decorate -5
```

Expected before coding: dirty tree is understood and unrelated work is preserved.

---

## Observations from the deep review

### Strong foundations already present or planned

- OneLink-native architecture is correct: external AI libraries are not the product runtime.
- `Llm::EventBus`, `llm_events`, monitoring summaries, payload sanitizer, runtime health, and OTel-compatible attrs exist.
- Structured output policy exists and primary plan adds semantic hardening.
- Tool registry and many native Captain tools exist across CRM, scheduling, knowledge, campaign, admin, and observability surfaces.
- Account-aware model routing exists through `config/llm.yml`, `lib/llm/config.rb`, and `lib/llm/models.rb`.
- Knowledge/RAG work is strong: document chunks, embeddings, `semantic_chunk` retrieval, reindex/backfill, `retrieval_trace`, degraded lexical fallback.
- Eval system exists and is moving toward Tribunal-style deterministic/live packs.
- Captain observability backend and frontend surfaces exist.

### Key gaps that remain after primary implementation unless explicitly closed

1. **Case Coverage Matrix is still the real final gate.**
   - The primary plan contains a matrix, but it must be filled with evidence for all major cases.

2. **ToolPolicy enterprise decision is unresolved.**
   - Current `Captain::ToolPolicy#runtime_allowed?` checks scope/features, while permission/risk/confirmation helper methods exist but are not part of the runtime decision.
   - Specs currently allow permissive behavior for custom/high-risk agent tools and assistant tools without separate per-user runtime permission gating.
   - This may be an intentional selection-time model, but it must be explicitly decided, documented, and tested for enterprise risk classes.

3. **Real-provider RAG PASS remains required.**
   - Primary plan recorded DEV code/runtime path smoke with a temporary local embeddings endpoint.
   - Full live PASS requires real DEV embedding provider credentials/model and smoke without the temporary endpoint.

4. **AI Voice parity is not proven complete.**
   - Voice context/tool dispatch exists, but full “same Captain brain” proof must cover shared rules/tools/RAG, confirmation parity, fillers/progress, latency, and eval traces.

5. **MCP/custom HTTP lifecycle is not complete as an enterprise product surface.**
   - Need account-scoped MCP servers, OAuth/PKCE, token refresh/revocation, stdio allowlist, permissions, confirmation, audit, timeout/output limits, and UI.

6. **Performance budgets are mostly targets, not measured proof.**
   - Need p50/p95/p99 and resource measurements per representative case.

7. **Image generation / advanced multimodal product decision is missing.**
   - `ruby_llm` supports more than text/tools/embeddings/audio. OneLink must decide whether image generation and richer multimodal flows are product features, admin-only features, or out of scope.

---

## Reference library adoption map

### `ruby_llm`

Take:

- provider/model abstraction;
- chat lifecycle;
- tools/function calling;
- attachments/content;
- embeddings;
- transcription;
- moderation;
- model capabilities/pricing.

Adapt into OneLink:

- account-aware credentials and provider routing;
- Captain/Copilot/AI Voice runtime state;
- OneLink tools and confirmation policy;
- product UI and operator evidence.

Do not take blindly:

- generic Rails chat UI as final product UX;
- generic agent abstractions that bypass Captain.

### `ruby_llm-schema`

Take:

- JSON Schema DSL and strict structured-output shape.

Adapt into OneLink:

- semantic validation after schema validation;
- invalid-output events;
- safe retry policy;
- case-specific schemas.

Do not treat as sufficient:

- valid JSON alone is not safe or correct output.

### `ruby_llm-mcp`

Take:

- MCP client/server/resource/tool concepts;
- OAuth/PKCE patterns;
- HTTP/SSE/stdio transport lessons.

Adapt into OneLink:

- account-scoped MCP connections;
- admin-controlled server registry;
- stdio allowlist;
- permission/confirmation/redaction/audit;
- tool lifecycle UI.

Do not take:

- arbitrary production stdio MCP access;
- user/server credentials outside OneLink secret policy.

### `ruby_llm-tribunal`

Take:

- datasets;
- deterministic assertions;
- LLM-as-judge patterns;
- red-team attacks;
- reporters.

Adapt into OneLink:

- Captain eval packs;
- AI Voice eval traces;
- RAG trace correctness;
- mutation safety evals;
- CI deterministic gates plus manual/scheduled live gates.

Do not take:

- evals as a replacement for RSpec/request/runtime specs.

### `ruby_llm-monitoring`

Take:

- persisted event summary ideas;
- cost/latency/error/throughput metrics;
- alert rule concepts;
- retention/authorization lessons.

Adapt into OneLink:

- product-native `llm_events` and Captain observability;
- account-scoped admin UI;
- no raw prompts by default;
- release gates and alert channels.

Do not take:

- mounted generic monitoring engine as final UX.

### `opentelemetry-instrumentation-ruby_llm`

Take:

- GenAI semantic attribute taxonomy;
- content capture off by default;
- span shape for chat/tool/embedding/transcription/moderation.

Adapt into OneLink:

- `Llm::EventBus` and OneLink metadata as source of truth;
- opt-in export;
- redacted product attrs.

Do not take:

- duplicate monkey-patched spans that lose product context or double-count events.

### `ai-agents`

Take as concepts:

- explicit handoff graph;
- serializable current-agent context;
- thread-safe runner lifecycle;
- callback/observability shape.

Adapt into OneLink:

- Captain scenarios/agents;
- current-agent persistence;
- handoff evals/traces;
- account-scoped tools.

Do not take:

- generic runner as replacement for Captain runtime.

## Addendum Etapas

## Addendum Etapa A — Plan Status Normalization

**Objective:** Make the primary plan and this addendum usable as the single source of truth.

**Files:**

- Modify: `.hermes/plans/2026-05-22_110801-onelink-native-ai-full-stack.md`
- Modify: `.hermes/plans/2026-05-26_102920-onelink-native-ai-full-stack-enterprise-addendum.md` if status changes during execution

**Steps:**

1. Read the top and bottom status sections of the primary plan.
2. Replace stale “No implementation started” language with an accurate status table.
3. Add a cross-link from the primary plan to this addendum.
4. Add a “Do not start addendum until...” gate.
5. Verify markdown readability.

**Verification:**

```bash
git diff -- .hermes/plans/2026-05-22_110801-onelink-native-ai-full-stack.md .hermes/plans/2026-05-26_102920-onelink-native-ai-full-stack-enterprise-addendum.md
```

**Acceptance Gate:**

A reader can tell exactly which Etapas are done, partial, blocked, and next without reading 2,000+ lines.

---

## Addendum Etapa B — Final Case Coverage Matrix

**Objective:** Convert the broad AI stack into explicit product-case proof.

**Cases to fill first:**

1. Customer support reply.
2. CRM deal create/update/search.
3. Scheduling appointment.
4. Touch/reminder/follow-up.
5. Campaign/template send.
6. Knowledge/RAG answer.
7. File/artifact send.
8. MCP/custom HTTP tool.
9. Internal assistant/admin operation.
10. AI Voice inbound call.
11. AI Voice post-call memory/FAQ.
12. Provider/model fallback failure.
13. Prompt injection / unsafe request.
14. Multimodal attachment understanding.
15. Optional image generation, if product-approved.


**For each case, fill:**

- Runtime path.
- Tool IDs and services.
- Structured output schema.
- Safety/permission/confirmation policy.
- Eval pack/case.
- Trace/event proof.
- Operator/admin UI proof.
- Performance budget.
- Test commands.
- Status: `not_started`, `partial`, `code_done`, `dev_pass`, `prod_pass`.

**Likely files:**

- `.hermes/plans/2026-05-22_110801-onelink-native-ai-full-stack.md`
- `lib/llm/evals/pack_registry.rb`
- `config/llm_evals/*.yml`
- `enterprise/lib/captain/evals/**/*`
- `spec/enterprise/lib/captain/evals/**/*`
- relevant tool specs under `spec/enterprise/lib/captain/tools/**/*`
- relevant service specs under `spec/enterprise/services/captain/**/*`

**Verification:**

- No case remains `TBD` without a written reason.
- Each top-5 case has at least one deterministic eval/spec.

**Acceptance Gate:**

The team can answer: “which AI product cases are enterprise-ready, which are partial, and why?”

---

## Addendum Etapa C — ToolPolicy Enterprise Decision

**Objective:** Decide and implement the final enterprise runtime policy for high-risk, admin, custom, HTTP, MCP, and mutation tools.

**Current concern:**

`Captain::ToolPolicy#runtime_allowed?` currently checks only scope/features. Permission, risk, and confirmation helper methods exist but are not part of the runtime decision. Existing specs allow permissive behavior for custom/high-risk tools and assistant tools without separate per-user runtime gates.

**Decision options:**

1. **Selection-time trust model:** once exposed by assistant/profile/rules, runtime allows it. Requires strong selection UI, audit, and confirmation at execution layer.
2. **Execute-time risk gate:** high-risk/custom/admin tools require runtime policy approval before execution.
3. **Hybrid model:** low-risk/capability tools use selection-time trust; high-risk/custom/admin/external tools require execute-time policy and/or confirmation.

**Recommended default:** Hybrid model.

**Likely files:**

- `enterprise/lib/captain/tool_policy.rb`
- `enterprise/lib/captain/tool_registry.rb`
- `enterprise/lib/captain/tool_execution_idempotency.rb`
- `enterprise/lib/captain/copilot/tool_confirmation_gate.rb`
- `enterprise/lib/captain/tools/**/*`
- `spec/enterprise/lib/captain/tool_policy_spec.rb`
- high-risk tool specs under `spec/enterprise/lib/captain/tools/**/*`

**Tasks:**

1. Inventory tool risk classes and confirmation metadata.
2. Classify tools into low/medium/high/custom/admin/external/money/outbound/destructive.
3. Decide final policy with user approval.
4. Write failing specs for blocked high-risk/custom/admin runtime cases.
5. Implement minimal policy.
6. Verify no low-risk tool regressions.
7. Add observability event for runtime block/confirmation required.

**Verification:**

```bash
RAILS_ENV=test DISABLE_SPRING=1 bundle exec rspec spec/enterprise/lib/captain/tool_policy_spec.rb --format progress
RAILS_ENV=test DISABLE_SPRING=1 bundle exec rspec spec/enterprise/lib/captain/tools --format progress
bundle exec ruby -c enterprise/lib/captain/tool_policy.rb
bundle exec rubocop --force-exclusion --fail-level E enterprise/lib/captain/tool_policy.rb spec/enterprise/lib/captain/tool_policy_spec.rb
```

**Acceptance Gate:**

No high-risk/custom/admin/external mutation tool can execute without the approved OneLink policy path, and prompt-visible/runtime-callable mismatch is avoided or explicitly documented.

---

## Addendum Etapa D — Real-Provider RAG PASS

**Objective:** Turn Etapa 9 code/fake-provider smoke into real provider readiness.

**Prerequisite:** Real DEV embedding provider/model credentials are configured through the approved OneLink config path.

**Likely files:**

- `config/llm.yml`
- `lib/llm/config.rb`
- `lib/llm/models.rb`
- `enterprise/app/models/captain/document_chunk.rb`
- `enterprise/app/jobs/captain/llm/update_embedding_job.rb`
- `enterprise/app/services/captain/documents/chunk_embedding_backfill_service.rb`
- `enterprise/lib/tasks/captain_knowledge.rake`
- `enterprise/lib/captain/tools/faq_lookup_tool.rb`
- `app/javascript/dashboard/routes/dashboard/captain/documents/**/*` if operator UI needs expansion

**Tasks:**

1. Verify DEV embedding provider/key/model config without printing secrets.
2. Create or reuse a safe test document for a DEV account/assistant.
3. Run chunk reindex/backfill.
4. Confirm chunks become `indexed` with real provider.
5. Run direct `Captain::DocumentChunk.search`.
6. Run `faq_lookup`/runtime-like path.
7. Confirm `retrieval_trace.strategy = semantic_chunk` and `degraded = false`.
8. Verify operator UI shows embedding health.
9. Remove temporary test content unless user wants it retained.

**Verification commands:**

Use environment-specific commands from the primary plan, but never print keys. Minimum proof:

- no pending migrations;
- chunk status `indexed`;
- direct search returns chunk id;
- `faq_lookup` returns `semantic_chunk`;
- trace `degraded=false`;
- UI/API exposes embedding health.

**Acceptance Gate:**

RAG uses real provider embeddings in DEV with no temporary fake endpoint, and the operator can see health/degraded state.

---

## Addendum Etapa E — AI Voice Full Captain Parity

**Objective:** Prove AI Voice uses the same Captain brain while preserving realtime voice transport constraints.

**Must prove:**

- same assistant instructions/rules/scenarios;
- same selected native tools where appropriate;
- same Knowledge/RAG behavior;
- same account/model routing;
- same safety/confirmation policy for high-risk tools;
- speech-safe fillers/progress during long tools;
- post-call memory/FAQ behavior;
- trace/eval evidence;
- latency budget.

**Likely files:**

- `app/services/telephony/ai_voice/context_builder.rb`
- `app/services/telephony/ai_voice/tool_dispatch_service.rb`
- `app/controllers/internal/voice/ai/*`
- `services/onelink-ai-voice/**/*` if Node runtime/session builder is involved
- `lib/llm/evals/ai_voice_trace_exporter.rb`
- `enterprise/lib/captain/evals/ai_voice_trace_suite.rb`
- `spec/requests/internal/voice/ai/**/*`
- `spec/services/telephony/ai_voice/**/*`

**Tasks:**

1. Build a text Captain vs AI Voice parity fixture for the same assistant/account.
2. Assert shared rules/tools/RAG availability.
3. Assert voice path does not force lexical-only RAG when semantic chunk retrieval is available.
4. Add filler/progress behavior for tool waits over the configured threshold.
5. Add confirmation parity for high-risk tools.
6. Add post-call memory/FAQ proof from transcript.
7. Add eval trace pack for voice parity.
8. Measure first-response and tool-wait latency.

**Verification:**

```bash
RAILS_ENV=test DISABLE_SPRING=1 bundle exec rspec spec/requests/internal/voice/ai spec/services/telephony/ai_voice spec/enterprise/lib/captain/evals/ai_voice_trace_suite_spec.rb --format progress
bundle exec ruby -c app/services/telephony/ai_voice/context_builder.rb
bundle exec ruby -c app/services/telephony/ai_voice/tool_dispatch_service.rb
```

**Acceptance Gate:**

For representative cases, text Captain and AI Voice share rules/tools/RAG/safety behavior, and Voice meets latency/filler requirements.

---

## Addendum Etapa F — MCP / Custom HTTP Enterprise Lifecycle

**Objective:** Turn MCP/custom tools into a safe product-grade integration surface.

**Scope:**

- account-scoped MCP server records;
- OAuth/PKCE or explicit credential flow;
- token refresh/revocation;
- tool discovery and approval;
- stdio allowlist;
- HTTP/SSE transport policy;
- tool output limits;
- prompt injection defenses;
- confirmation and permission mapping;
- audit/redaction;
- UI for admins;
- evals for unsafe tools.

**Likely files:**

- existing `Captain::CustomTool` surfaces;
- `enterprise/lib/captain/tools/http_request_executor.rb`
- `enterprise/app/models/captain/custom_tool.rb`
- `enterprise/lib/captain/tool_registry.rb`
- `enterprise/lib/captain/tool_access.rb`
- `enterprise/lib/captain/tool_policy.rb`
- new MCP models/services/controllers only if approved
- `app/javascript/dashboard/routes/dashboard/captain/**/*`

**Tasks:**

1. Inventory existing custom HTTP tool model and executor.
2. Define MCP server/account credential model.
3. Add allowlist/transport policy.
4. Add tool discovery import with explicit admin approval.
5. Add runtime execution adapter through existing Captain tool contracts.
6. Add redaction/output byte limits.
7. Add confirmation policy for mutation/external tools.
8. Add UI for server connection, discovered tools, enable/disable, revoke.
9. Add evals for unsafe tool/prompt injection.

**Acceptance Gate:**

An account admin can connect/approve/revoke MCP/custom tools safely, and Captain can call approved tools with bounded output, audit, confirmation, and eval coverage.

---

## Addendum Etapa G — Multimodal / Image Generation Product Decision

**Objective:** Decide and implement, if approved, advanced multimodal and image-generation product surfaces from RubyLLM capabilities.

**Candidate surfaces:**

- image understanding in support conversations;
- document/file understanding;
- audio/video attachment summaries;
- AI-generated campaign images;
- AI-generated knowledge illustrations;
- internal admin image generation only;
- no image generation, only image understanding.

**Risks:**

- cost spikes;
- unsafe generated media;
- brand/legal review;
- attachment retention;
- customer privacy;
- channel delivery constraints.

**Acceptance Gate:**

Product decision exists. If implemented, the feature has account permissions, safety/moderation, cost budgets, UI, evals, and trace evidence.

---

## Addendum Etapa H — Eval Quality Gate Productionization

**Objective:** Make evals a reliable engineering/product safety gate, not a demo page.

**Requirements:**

- deterministic CI pack;
- manual/scheduled live pack;
- budget enforcement;
- red-team pack;
- RAG trace pack;
- AI Voice trace pack;
- tool mutation safety pack;
- prompt injection pack;
- result summarization only;
- historical trend UI;
- retry/cancel/autopoll if not already finished.

**Likely files:**

- `lib/llm/evals/pack_registry.rb`
- `config/llm_evals/*.yml`
- `enterprise/lib/captain/evals/**/*`
- `app/models/llm/eval_run.rb`
- `app/jobs/llm/evals/run_job.rb`
- `app/controllers/api/v1/accounts/captain/evaluations_controller.rb`
- `app/javascript/dashboard/routes/dashboard/captain/evaluations/**/*`
- specs around all of the above

**Verification:**

```bash
RAILS_ENV=test DISABLE_SPRING=1 bundle exec rspec spec/lib/llm/evals spec/enterprise/lib/captain/evals spec/jobs/llm/evals spec/controllers/api/v1/accounts/captain/evaluations_controller_spec.rb --format progress
pnpm exec eslint app/javascript/dashboard/routes/dashboard/captain/evaluations app/javascript/dashboard/api/captain/evaluations.js
pnpm exec vitest --no-watch --no-cache --no-coverage app/javascript/dashboard/routes/dashboard/captain/evaluations app/javascript/dashboard/api/specs/captainEvaluations.spec.js
```

**Acceptance Gate:**

A normal AI change can add/modify eval cases, deterministic CI remains cheap, and live evals are budgeted and explicit.

---

## Addendum Etapa I — Performance, Load, and Canary Proof

**Objective:** Prove the AI stack is fast and resource-efficient under representative enterprise load.

**Measure per case:**

- p50/p95/p99 total latency;
- provider latency;
- queue wait;
- DB writes/run;
- event payload bytes;
- prompt/completion/thinking tokens;
- estimated cost;
- tool execution duration;
- RAG retrieval duration;
- error/fallback/degraded rates;
- worker memory growth;
- noisy-neighbor/account isolation.

**Likely files:**

- `lib/llm/monitoring/**/*`
- `enterprise/app/controllers/api/v1/accounts/captain/observability_controller.rb`
- `app/javascript/dashboard/routes/dashboard/captain/observability/**/*`
- Sidekiq queue configs
- deployment/runbook docs

**Tasks:**

1. Define benchmark fixtures for top-5 cases.
2. Add a safe non-prod benchmark runner or documented manual script.
3. Run DEV baseline.
4. Run canary/prod-safe sample after approval.
5. Store summarized results in the plan or internal docs.
6. Add alerts if thresholds are exceeded.

**Acceptance Gate:**

Enterprise readiness claims include measured latency/resource/cost numbers, not only target budgets.

---

## Addendum Etapa J — Operator Explainability UI Finalization

**Objective:** Make “why did AI do this?” answerable from OneLink UI without reading logs.

**Representative operator questions:**

- Which model/provider handled this run?
- Which assistant/rules/scenario were active?
- Which tools were available?
- Which tools were called and with what redacted inputs/outputs?
- Was confirmation required or skipped?
- Was RAG semantic or lexical degraded fallback?
- Which document chunks/sources were used?
- Did schema repair/retry happen?
- Did safety/moderation block anything?
- How much did it cost?
- What was the latency/queue wait?
- Which eval case covers this behavior?

**Likely files:**

- `enterprise/app/controllers/api/v1/accounts/captain/observability_controller.rb`
- `lib/llm/monitoring/events_query.rb`
- `app/javascript/dashboard/routes/dashboard/captain/observability/Index.vue`
- `app/javascript/dashboard/routes/dashboard/captain/observability/EventDetailsDialog.vue`
- `app/javascript/dashboard/api/captain/observability.js`

**Verification:**

```bash
pnpm exec eslint app/javascript/dashboard/routes/dashboard/captain/observability app/javascript/dashboard/api/captain/observability.js
pnpm exec vitest --no-watch --no-cache --no-coverage app/javascript/dashboard/routes/dashboard/captain/observability
RAILS_ENV=test DISABLE_SPRING=1 bundle exec rspec spec/controllers/api/v1/accounts/captain/observability_controller_spec.rb --format progress
```

**Acceptance Gate:**

For at least five representative AI runs, an operator can answer the questions above from UI/API with redacted data only.

---

## Addendum Etapa K — Enterprise Rollout / Runbook / Docs

**Objective:** Make the completed AI stack operable by humans.

**Docs to produce/update:**

- internal architecture of OneLink AI stack;
- runtime surfaces and model routing;
- tool safety policy;
- eval workflow;
- observability/run trace guide;
- RAG indexing/reindex guide;
- MCP/custom tool admin guide;
- AI Voice parity guide;
- performance budget and canary checklist;
- incident RCA playbook.

**Likely files:**

- `docs/internal/**/*` through the docs submodule workflow;
- `.hermes/plans/**/*` for implementation status;
- deployment/runbook docs if runtime operations change.

**Acceptance Gate:**

A new engineer/operator can understand, deploy, debug, and safely operate OneLink AI without private tribal knowledge.

---

## Final enterprise acceptance checklist

The addendum is complete only when all of these are true:

- [ ] Primary plan status is normalized and linked to this addendum.
- [ ] Case Coverage Matrix has no unexplained `TBD` entries.
- [ ] Top-5 cases have runtime + tools + schema + safety + eval + trace + UI + perf proof.
- [ ] ToolPolicy enterprise decision is documented and tested.
- [ ] RAG real-provider DEV PASS is complete.
- [ ] RAG production/canary path is documented and approved before prod rollout.
- [ ] AI Voice parity is proven for representative cases.
- [ ] MCP/custom HTTP lifecycle is either complete or explicitly out of scope.
- [ ] Image generation / advanced multimodal has an explicit product decision.
- [ ] Eval system has deterministic CI gate and budgeted live gate.
- [ ] Operator UI can explain representative AI runs.
- [ ] Performance/load/cost numbers are measured.
- [ ] Retention/redaction/no-raw-content policy is verified across events, OTel, UI, exports, evals, and tool traces.
- [ ] Internal docs/runbooks are updated.
- [ ] Production rollout is staged, canaried, monitored, and reversible.

---

## Recommended first task after the primary plan completes

Start with **Addendum Etapa B — Final Case Coverage Matrix**.

Reason: it prevents random feature expansion and forces the enterprise AI stack to close around real OneLink product scenarios.

Do not begin with MCP, image generation, or extra UI until the top product cases prove the core stack.
