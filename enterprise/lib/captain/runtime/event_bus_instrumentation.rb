# frozen_string_literal: true

class Captain::Runtime::EventBusInstrumentation
  INSTALL_MUTEX = Mutex.new
  INSTRUMENTATION_FLAG_IVAR = :@__captain_runtime_event_bus_installed

  class << self
    def install(runner)
      INSTALL_MUTEX.synchronize do
        return runner if instrumentation_installed?(runner)

        callbacks = Captain::Runtime::EventBusCallbacks.new

        Captain::Runtime::CallbackManager::EVENT_TYPES.each do |event|
          next unless callbacks.respond_to?(:"on_#{event}")

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
  end
end
