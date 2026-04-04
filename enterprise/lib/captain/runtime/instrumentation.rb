# frozen_string_literal: true

class Captain::Runtime::Instrumentation
  INSTALL_MUTEX = Mutex.new
  INSTRUMENTATION_FLAG_IVAR = :@__captain_runtime_otel_installed

  class << self
    def install(runner, tracer:, trace_name:, span_attributes: {}, attribute_provider: nil)
      return unless otel_available?

      INSTALL_MUTEX.synchronize do
        return runner if instrumentation_installed?(runner)

        callbacks = Captain::Runtime::TracingCallbacks.new(
          tracer: tracer,
          trace_name: trace_name,
          span_attributes: span_attributes,
          attribute_provider: attribute_provider
        )

        Captain::Runtime::CallbackManager::EVENT_TYPES.each do |event|
          runner.public_send(:"on_#{event}") { |*args| callbacks.public_send(:"on_#{event}", *args) }
        end

        mark_instrumentation_installed(runner)
      end

      runner
    end

    private

    def instrumentation_installed?(runner)
      runner.instance_variable_get(INSTRUMENTATION_FLAG_IVAR)
    end

    def mark_instrumentation_installed(runner)
      runner.instance_variable_set(INSTRUMENTATION_FLAG_IVAR, true)
    end

    def otel_available?
      require 'opentelemetry-api'
      true
    rescue LoadError
      false
    end
  end
end
