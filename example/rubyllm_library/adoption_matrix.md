# Adoption Matrix: RubyLLM Ecosystem → OneLink

## Иерархия решений

1. **OneLink product runtime** — финальная точка внедрения.
2. **`ruby_llm` core** — первый источник возможностей.
3. **Secondary libraries** — берём только лучший/богатый слой, если он усиливает OneLink:
   - instrumentation taxonomy;
   - monitoring persistence/metrics;
   - alert rules;
   - eval patterns;
   - MCP integration patterns.

## Матрица

### `ruby_llm`

- **Брать как основу:** chat lifecycle, provider/model abstraction, `RubyLLM.context`, tools, content/attachments, embeddings/transcription surfaces, model metadata/pricing.
- **Адаптировать в OneLink:** account-aware routing, product permissions, Captain tools, conversation state, channel policies, retries/fallbacks.
- **Не делать:** заменять Captain orchestration generic agent layer без product guardrails.

### `ruby_llm-schema`

- **Брать как основу:** strict structured output contract, schema validation, JSON schema generation.
- **Адаптировать в OneLink:** semantic validation, schema repair/retry, `schema_name`, invalid-output events, eval cases.
- **Не делать:** считать валидный JSON гарантией качественного ответа.

### `ruby_llm-mcp`

- **Брать как основу:** MCP client semantics, server/tool/resource/task concepts, OAuth/PKCE patterns.
- **Адаптировать в OneLink:** account-scoped MCP servers, production-safe HTTP transports, stdio allowlist, secret redaction, tool access UI.
- **Не делать:** включать arbitrary stdio MCP в production без allowlist.

### `ruby_llm-tribunal`

- **Брать как основу:** datasets, judges, red-team/eval runner concepts.
- **Адаптировать в OneLink:** Captain/AI Voice eval packs, brand voice judge, tool-choice judge, mutation safety judge, CI gates.
- **Не делать:** заменять RSpec; evals дополняют тесты, а не заменяют runtime specs.

### `opentelemetry-instrumentation-ruby_llm`

- **Брать как основу:** `gen_ai.*` semantic span attributes, chat/tool/embedding span shape, content capture off by default, per-chat custom attributes.
- **Адаптировать в OneLink:** использовать как standard taxonomy внутри `Integrations::LlmInstrumentation` / `Llm::EventBus` / OTel export; добавить product attributes: `account_id`, `assistant_id`, `conversation_id`, `copilot_thread_id`, `schema_name`, `tool_id`, `run_id`.
- **Не делать:** слепо prepend-patch RubyLLM в обход текущей Captain instrumentation, если это даст дубль spans или потерю product context.

### `ruby_llm-monitoring`

- **Брать как основу:** persisted summarized events, cost calculation from model pricing, throughput/cost/latency/error metrics, alert rules, channel registry.
- **Адаптировать в OneLink:** хранить AI run summary в product-native таблицах/моделях или совместимом event store; показывать в OneLink admin/Captain UI; добавить retention; не хранить raw prompts по умолчанию.
- **Не делать:** монтировать engine UI публично/без auth; создавать второй monitoring dashboard вне OneLink UX.

## Target stack after adoption

- Runtime: `ruby_llm` + OneLink `Llm::ChatClient` / Captain runtime.
- Structured output: `ruby_llm-schema` + OneLink semantic policy.
- Tools: OneLink native tools + MCP where useful.
- Quality: `ruby_llm-tribunal` evals + RSpec.
- Observability: OTel GenAI-compatible spans + persisted AI event summaries.
- Operations: alerts, cost/latency/error dashboards, run trace UI.

## Критерий “берём вторичную библиотеку”

Берём только если она даёт минимум одно:

- стандарт, который лучше нашего текущего naming/shape;
- готовую концепцию, которая экономит много времени;
- функционал, которого нет в `ruby_llm` core;
- качественные tests/examples, которые можно перенести в OneLink;
- operational value: RCA, latency, cost, alerts, evals.
