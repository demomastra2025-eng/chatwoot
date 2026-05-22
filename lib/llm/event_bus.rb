# frozen_string_literal: true

require 'securerandom'

class Llm::EventBus
  EVENT_NAMESPACE = 'llm'
  CONTEXT_STATE_KEY = :llm_event_bus_context_stack
  EVENT_NAME_ALIASES = {
    'llm.run.started' => 'llm.run.start',
    'llm.run.finished' => 'llm.run.complete',
    'llm.run.failed' => 'llm.run.complete',
    'llm.tool.started' => 'llm.tool.execute',
    'llm.tool.finished' => 'llm.tool.complete',
    'llm.tool.failed' => 'llm.tool.complete',
    'llm.schema.repair' => 'llm.schema.repair_requested'
  }.freeze
  CONTEXT_KEYS = %w[
    request_id trace_id session_id account_id assistant_id conversation_id
    conversation_display_id copilot_thread_id current_agent channel_type source
    feature runtime_mode project_case_id
  ].freeze

  class << self
    def publish(event_name, payload = {})
      normalized_event_name = full_event_name(event_name)
      event_name_for_publish = canonical_event_name(normalized_event_name)
      normalized_payload = normalize_payload(payload).merge(
        'canonical_event_name' => event_name_for_publish
      )
      normalized_payload['event_name_alias'] = normalized_event_name if normalized_event_name != event_name_for_publish

      with_context(normalized_payload) do
        if block_given?
          ActiveSupport::Notifications.instrument(event_name_for_publish, normalized_payload) do |instrument_payload|
            yield(instrument_payload || normalized_payload)
          end
        else
          ActiveSupport::Notifications.instrument(event_name_for_publish, normalized_payload)
        end
      end
    end

    def with_context(payload = {})
      context_payload = extract_context_payload(payload)
      return yield if context_payload.empty?

      pushed = false
      context_stack.push(context_payload)
      pushed = true
      yield
    ensure
      if pushed
        context_stack.pop
        ActiveSupport::IsolatedExecutionState[CONTEXT_STATE_KEY] = nil if context_stack.empty?
      end
    end

    private

    def full_event_name(event_name)
      event_name = event_name.to_s
      return event_name if event_name.start_with?("#{EVENT_NAMESPACE}.")

      "#{EVENT_NAMESPACE}.#{event_name}"
    end

    def canonical_event_name(event_name)
      EVENT_NAME_ALIASES.fetch(event_name, event_name)
    end

    def normalize_payload(payload)
      current_context.merge(payload.to_h.each_with_object({}) do |(key, value), result|
        result[key.to_s] = value
      end).tap do |normalized|
        normalized['request_id'] = normalized['request_id'].presence || normalized['trace_id'].presence || SecureRandom.uuid
      end
    end

    def extract_context_payload(payload)
      payload.to_h.each_with_object({}) do |(key, value), result|
        string_key = key.to_s
        next unless CONTEXT_KEYS.include?(string_key)
        next if value.blank?

        result[string_key] = value
      end
    end

    def current_context
      context_stack.last || {}
    end

    def context_stack
      ActiveSupport::IsolatedExecutionState[CONTEXT_STATE_KEY] ||= []
    end
  end
end
