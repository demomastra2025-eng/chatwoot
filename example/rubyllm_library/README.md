# RubyLLM Library Examples For OneLink

Назначение папки: держать короткие проверенные примеры и выводы по RubyLLM-экосистеме для внедрения в основной OneLink/Captain runtime.

## Принцип внедрения

1. **OneLink — основной фреймворк и product runtime.**
   - Не заменяем Captain orchestration, `Llm::EventBus`, product-specific tools, account routing, UI и security policy внешними demo-движками.
   - Все внешние библиотеки проходят через OneLink-контракты: account scope, permissions, confirmations, redaction, audit, evals, admin UX.

2. **`ruby_llm` — primary source.**
   - Сначала берём core runtime capabilities из `ruby_llm`: chat, models, tools, context, attachments/content, embeddings/transcription surfaces, model metadata.
   - Если нужная возможность уже качественно есть в `ruby_llm`, не дублируем её в OneLink.

3. **Вторичные библиотеки — selective adoption.**
   - Берём только тот функционал, который богаче/качественнее, чем текущий OneLink слой или core `ruby_llm`.
   - Внешний код используется как reference/adaptation source, а не как слепая замена runtime.

## Добавленные reference libraries

- [`thoughtbot/opentelemetry-instrumentation-ruby_llm`](https://github.com/thoughtbot/opentelemetry-instrumentation-ruby_llm)
  - просмотренный SHA: `9a97ca4357c8e79aa24b82f2bf129bb3d73d15c5`
  - роль: OpenTelemetry GenAI span taxonomy, content-capture toggle, generic tracing for chat/tools/embeddings.
  - детали: `secondary_libraries/opentelemetry_instrumentation_ruby_llm.md`

- [`sinaptia/ruby_llm-monitoring`](https://github.com/sinaptia/ruby_llm-monitoring)
  - просмотренный SHA: `0ea642dbb07f293013d74b0d4f6a76d932002066`
  - роль: persisted monitoring events, cost/latency/error metrics, alert rules, Rails engine reference.
  - детали: `secondary_libraries/ruby_llm_monitoring.md`

## Что это меняет в финальной архитектуре

- `ruby_llm` остаётся базой runtime.
- `ruby_llm-schema`, `ruby_llm-mcp`, `ruby_llm-tribunal` остаются функциональными слоями Captain.
- `opentelemetry-instrumentation-ruby_llm` добавляет эталонную форму OTel/GenAI spans.
- `ruby_llm-monitoring` добавляет эталонную форму persisted metrics/alerts.
- OneLink должен объединить это в один product-native наблюдаемый AI runtime: trace + metrics + evals + tools + confirmations + admin UI.

## Файлы

- `adoption_matrix.md` — что брать напрямую, что адаптировать, что не брать.
- `secondary_libraries/opentelemetry_instrumentation_ruby_llm.md` — разбор thoughtbot OTel gem.
- `secondary_libraries/ruby_llm_monitoring.md` — разбор Sinaptia monitoring gem.
- `snippets/opentelemetry_initializer.rb` — пример безопасного initializer pattern.
- `snippets/ruby_llm_monitoring_initializer.rb` — пример monitoring/alerts config pattern.
