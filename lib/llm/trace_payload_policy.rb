# frozen_string_literal: true

class Llm::TracePayloadPolicy
  CAPTURE_KEYS = {
    input: 'trace_input_capture',
    output: 'trace_output_capture'
  }.freeze
  REDACTION_HOOKS_MUTEX = Mutex.new

  class << self
    def capture(value, direction:, account: nil, preferences: nil)
      return nil unless capture_enabled?(direction, account: account, preferences: preferences)

      sanitized = sanitize(value, direction: direction, account: account, preferences: preferences)
      serialize(sanitized).presence
    end

    def sanitize(value, direction:, account: nil, preferences: nil)
      payload = apply_redaction_hooks(
        value,
        direction: direction,
        account: account,
        preferences: preferences
      )

      Llm::Monitoring::PayloadSanitizer.call(payload)
    end

    def trace_attributes(account: nil, preferences: nil)
      {
        'trace_input_capture' => trace_input_capture?(account: account, preferences: preferences),
        'trace_output_capture' => trace_output_capture?(account: account, preferences: preferences)
      }
    end

    def trace_input_capture?(account: nil, preferences: nil)
      Llm::RuntimePolicy.trace_input_capture?(account: account, preferences: preferences)
    end

    def trace_output_capture?(account: nil, preferences: nil)
      Llm::RuntimePolicy.trace_output_capture?(account: account, preferences: preferences)
    end

    def register_redaction_hook(name = nil, &block)
      return unless block

      REDACTION_HOOKS_MUTEX.synchronize do
        redaction_hooks << { name: name, block: block }
      end
    end

    def reset_redaction_hooks!
      REDACTION_HOOKS_MUTEX.synchronize do
        @redaction_hooks = []
      end
    end

    private

    def capture_enabled?(direction, account:, preferences:)
      case direction.to_sym
      when :input
        trace_input_capture?(account: account, preferences: preferences)
      when :output
        trace_output_capture?(account: account, preferences: preferences)
      else
        false
      end
    end

    def apply_redaction_hooks(value, direction:, account:, preferences:)
      redaction_hooks.reduce(value) do |current_value, hook|
        hook[:block].call(
          current_value,
          direction: direction,
          account: account,
          preferences: preferences
        )
      end
    end

    def redaction_hooks
      @redaction_hooks ||= []
    end

    def serialize(value)
      return if value.nil?

      value.is_a?(Hash) || value.is_a?(Array) ? value.to_json : value.to_s
    end
  end
end
