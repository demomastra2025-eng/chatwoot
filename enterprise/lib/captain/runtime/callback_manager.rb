# frozen_string_literal: true

class Captain::Runtime::CallbackManager
  EVENT_TYPES = %i[
    run_start
    run_complete
    agent_complete
    tool_requested
    tool_start
    tool_progress
    tool_complete
    agent_thinking
    llm_call_complete
    llm_step
    chat_created
    answer_delta
  ].freeze

  def initialize(callbacks = {})
    @callbacks = callbacks.dup.freeze
  end

  # Whether anything listens to the event (a run that nobody listens to does not do the work that only the listener needs).
  def listening?(event_type)
    Array(@callbacks[event_type]).any?
  end

  def emit(event_type, *args)
    callback_list = @callbacks[event_type] || []

    callback_list.each do |callback|
      callback.call(*arity_safe_args(callback, args))
    rescue StandardError => e
      Rails.logger.warn "[Captain::Runtime] Callback error for #{event_type}: #{e.message}"
    end
  end

  EVENT_TYPES.each do |event_type|
    define_method("emit_#{event_type}") do |*args|
      emit(event_type, *args)
    end
  end

  private

  def arity_safe_args(callback, args)
    return args unless callback.lambda?
    return args if callback.parameters.any? { |type, _| type == :rest }

    max = callback.parameters.count { |type, _| %i[req opt].include?(type) }
    args.first(max)
  end
end
