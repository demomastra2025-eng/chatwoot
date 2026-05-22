# thoughtbot/opentelemetry-instrumentation-ruby_llm

Source: https://github.com/thoughtbot/opentelemetry-instrumentation-ruby_llm
Reviewed SHA: `9a97ca4357c8e79aa24b82f2bf129bb3d73d15c5`

## Что делает

Gem добавляет OpenTelemetry instrumentation для RubyLLM:

- `OpenTelemetry::Instrumentation::RubyLLM`
- patches:
  - `RubyLLM::Chat#complete`
  - `RubyLLM::Chat#execute_tool`
  - `RubyLLM::Embedding.embed`
- spans по OpenTelemetry GenAI semantic conventions.

## Подключение из README

```ruby
OpenTelemetry::SDK.configure do |c|
  c.use 'OpenTelemetry::Instrumentation::RubyLLM'
end
```

Опциональный capture content:

```ruby
OpenTelemetry::SDK.configure do |c|
  c.use 'OpenTelemetry::Instrumentation::RubyLLM', capture_content: true
end
```

Или env:

```bash
OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT=true
```

## Что реально полезно для OneLink

### 1. GenAI span naming

Примеры атрибутов из gem:

- `gen_ai.operation.name`
- `gen_ai.provider.name`
- `gen_ai.request.model`
- `gen_ai.response.model`
- `gen_ai.usage.input_tokens`
- `gen_ai.usage.output_tokens`
- `gen_ai.request.temperature`
- `gen_ai.tool.name`
- `gen_ai.tool.call.id`
- `gen_ai.tool.call.arguments`
- `gen_ai.tool.call.result`
- `gen_ai.embeddings.dimension.count`
- `error.type`

**OneLink action:** привести наши `Integrations::LlmInstrumentation`, `Captain::Runtime::Instrumentation`, `Llm::EventBus` к совместимому naming, не обязательно ставить generic patch как единственный источник событий.

### 2. Privacy model

Content capture выключен по умолчанию. При включении добавляются:

- `gen_ai.system_instructions`
- `gen_ai.input.messages`
- `gen_ai.output.messages`

**OneLink action:** такой же флаг нужен отдельно для production:

- default: metadata only;
- debug/canary: limited content capture;
- redaction before export;
- no tokens/secrets/raw customer attachments.

### 3. Custom per-chat attributes

Gem добавляет:

```ruby
chat.with_otel_attributes(
  "langfuse.observation.prompt.name" => "...",
  "langfuse.trace.tags" => ["..."],
  "langfuse.trace.metadata" => { feature: "captain" }.to_json
)
```

**OneLink action:** аналог нужен для product metadata:

- `one_link.account_id`
- `one_link.assistant_id`
- `one_link.conversation_id`
- `one_link.inbox_id`
- `one_link.copilot_thread_id`
- `one_link.feature`
- `one_link.schema_name`
- `one_link.tool_id`
- `one_link.run_id`

## Limitations / что не брать слепо

- Generic patch не знает Captain orchestration.
- Streaming в README помечен как planned.
- Conversation tracking `gen_ai.conversation.id` planned, а нам нужен product conversation id сейчас.
- Tool result truncation `result_str[0..500]` полезна, но для OneLink нужен redaction + structured output, не просто строка.
- Может дублировать spans, если включить рядом с текущим custom instrumentation без координации.

## Рекомендация

**Не заменять OneLink tracing этим gem напрямую.**
Использовать как эталон OTel/GenAI taxonomy и, если ставим gem, включать осторожно:

1. metadata-only;
2. без content capture в production;
3. с product attributes;
4. с проверкой дублей spans;
5. с отдельными spans/events для schema retry, tool policy, confirmation, handoff, safety block.

## Минимальный OneLink-compatible pattern

См. `../snippets/opentelemetry_initializer.rb`.
