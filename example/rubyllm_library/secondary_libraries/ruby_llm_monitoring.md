# sinaptia/ruby_llm-monitoring

Source: https://github.com/sinaptia/ruby_llm-monitoring
Reviewed SHA: `0ea642dbb07f293013d74b0d4f6a76d932002066`

## Что делает

Rails engine для мониторинга RubyLLM usage:

- subscribes to `ActiveSupport::Notifications` matching `/ruby_llm/`;
- persists `RubyLLM::Monitoring::Event`;
- dashboard `/monitoring`;
- metrics:
  - throughput;
  - cost;
  - response time;
  - error count/rate;
- alert rules;
- built-in channels:
  - Slack;
  - Email;
- custom channels.

## Подключение из README

```ruby
gem "ruby_llm-monitoring"
```

```bash
rails ruby_llm_monitoring:install:migrations db:migrate
```

```ruby
Rails.application.routes.draw do
  mount RubyLLM::Monitoring::Engine, at: "/monitoring"
end
```

Важно: auth/authorization оставлены приложению. Без защиты `/monitoring` доступен всем.

## Event persistence shape

`EventSubscriber` сохраняет:

- `allocations`
- `cpu_time`
- `duration`
- `gc_time`
- `idle_time`
- `name`
- `payload` без `:chat` и `:response`
- `time/end`
- `transaction_id`

Миграция добавляет generated/virtual columns из JSON payload:

- `provider`
- `model`
- `input_tokens`
- `output_tokens`
- `thinking_tokens`
- `exception_class`
- `exception_message`

Cost считается через `RubyLLM::Models.find(payload["model"], payload["provider"])` и model pricing.

## Что реально полезно для OneLink

### 1. Persisted summarized AI events

OneLink нужен такой же слой, но product-native:

- `account_id`
- `assistant_id`
- `conversation_id`
- `message_id`
- `inbox_id`
- `copilot_thread_id`
- `feature`
- `provider`
- `model`
- `schema_name`
- `tool_id/tool_name`
- `input_tokens/output_tokens/thinking_tokens`
- `estimated_cost`
- `duration_ms`
- `status`
- `error_class/error_code`
- `run_id/trace_id`

### 2. Metrics

Можно адаптировать как OneLink admin metrics:

- throughput by feature/provider/model;
- cost by account/assistant/provider/model;
- latency p50/p95 by surface;
- error rate by feature/tool/provider;
- schema invalid rate;
- tool timeout/failure rate;
- confirmation-required/blocked count.

### 3. Alerts

Useful alert rules:

- provider errors > threshold;
- schema invalid spikes;
- tool failures > threshold;
- cost exceeds daily/monthly budget;
- embeddings unavailable;
- Sidekiq `captain_runtime` queue backlog;
- AI Voice latency over threshold.

## Limitations / что не брать слепо

- Engine UI не подходит как основной OneLink UX.
- Auth не встроен — нельзя монтировать публично без constraints.
- События generic RubyLLM, не знают Captain-specific lifecycle.
- Нет retention by default; данные хранятся indefinitely.
- Payload persistence нужно проверять на PII/secrets.
- Зависит от `ruby_llm-instrumentation >= 0.1`; у OneLink уже есть кастомная instrumentation/event bus.

## Рекомендация

**Брать концепт, не UI как есть.**

Правильный OneLink вариант:

1. Сохранять summarized AI events из нашего `Llm::EventBus`.
2. Использовать pricing из `RubyLLM::Models` там, где модель есть в registry.
3. Показывать metrics в OneLink admin/Captain observability UI.
4. Добавить retention job.
5. Добавить alert rules через OneLink notifications/Slack/email.
6. Не хранить raw prompt/output по умолчанию.

## Минимальный OneLink-compatible pattern

См. `../snippets/ruby_llm_monitoring_initializer.rb`.
