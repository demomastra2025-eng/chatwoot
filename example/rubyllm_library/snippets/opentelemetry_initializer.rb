# frozen_string_literal: true

# Example only. Do not copy blindly into production.
# Goal: use thoughtbot/opentelemetry-instrumentation-ruby_llm as a taxonomy/reference
# while keeping OneLink/Captain product context and privacy controls.

# Gemfile candidate:
# gem 'opentelemetry-instrumentation-ruby_llm', require: false

if ENV.fetch('ONELINK_RUBY_LLM_OTEL_ENABLED', 'false') == 'true'
  require 'opentelemetry/sdk'
  require 'opentelemetry/exporter/otlp'
  require 'opentelemetry-instrumentation-ruby_llm'

  OpenTelemetry::SDK.configure do |config|
    config.service_name = ENV.fetch('OTEL_SERVICE_NAME', 'onelink-chatwoot')

    # Keep content capture off by default. Prompts/customer messages may contain PII.
    config.use(
      'OpenTelemetry::Instrumentation::RubyLLM',
      capture_content: ENV.fetch('ONELINK_LLM_TRACE_CAPTURE_CONTENT', 'false') == 'true'
    )
  end
end

# Example per-chat metadata pattern for OneLink runtime code:
#
# chat.with_otel_attributes(
#   'one_link.account_id' => account.id,
#   'one_link.assistant_id' => assistant.id,
#   'one_link.conversation_id' => conversation.id,
#   'one_link.inbox_id' => inbox.id,
#   'one_link.feature' => 'captain_agent',
#   'one_link.schema_name' => schema_name,
#   'one_link.run_id' => run_id
# )
#
# Required hardening before production:
# - avoid duplicate spans with Integrations::LlmInstrumentation / Llm::EventBus;
# - redact tool args/results;
# - add product events for schema retry, confirmation_required, handoff, safety_blocked;
# - keep raw message content disabled except short-lived debug/canary mode.
