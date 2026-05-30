# frozen_string_literal: true

class Captain::Runtime::ToolWrapper
  TOOL_NOT_BOUND_ERROR = 'Tool is not available for the current agent runtime'

  def initialize(tool, context_wrapper)
    @tool = tool
    @context_wrapper = context_wrapper
    @name = tool.name
    @description = tool.description
    @params = tool.class.params if tool.class.respond_to?(:params)
  end

  def call(args)
    tool_context = Captain::Runtime::ToolContext.new(run_context: @context_wrapper)
    normalized_args = normalize_args(args)

    @context_wrapper.callback_manager.emit_tool_start(@tool.name, normalized_args, @context_wrapper)

    pre_execution_error = pre_execution_error(normalized_args)
    return complete_and_render(pre_execution_error) if pre_execution_error

    result = @tool.execute(tool_context, **normalized_args)
    result_error = tool_safety_error_for(:tool_results, safety_checked_result(result))
    final_result = result_error || result
    @context_wrapper.callback_manager.emit_tool_complete(@tool.name, final_result, @context_wrapper)
    return final_result if halt_result?(final_result)

    Captain::ToolResult.render(final_result)
  rescue StandardError => e
    @context_wrapper.callback_manager.emit_tool_complete(
      @tool.name,
      Captain::ToolResult.failure(error: e),
      @context_wrapper
    )
    raise
  end

  def name
    @name || @tool.name
  end

  def description
    @description || @tool.description
  end

  def parameters
    @tool.parameters
  end

  def params_schema
    @tool.respond_to?(:params_schema) ? @tool.params_schema : nil
  end

  def provider_params
    @tool.respond_to?(:provider_params) ? @tool.provider_params : {}
  end

  def to_s
    name
  end

  private

  def normalize_args(args)
    return {} if args.nil?

    raw_args = args.respond_to?(:to_h) ? args.to_h : {}
    normalized = raw_args.deep_symbolize_keys
    normalized = normalized[:parameters].deep_symbolize_keys if tool_call_envelope?(normalized)

    unwrap_nested_tool_call_envelopes(normalized)
  rescue StandardError
    {}
  end

  def tool_call_envelope?(args)
    args[:name].present? && args[:parameters].is_a?(Hash)
  end

  def unwrap_nested_tool_call_envelopes(args)
    args.each_with_object({}) do |(key, value), normalized|
      normalized[key] = nested_tool_call_parameter_value(key, value)
    end
  end

  def nested_tool_call_parameter_value(key, value)
    return value unless value.is_a?(Hash)

    parameters = value.with_indifferent_access[:parameters]
    return value unless parameters.is_a?(Hash)

    parameters.with_indifferent_access.fetch(key, value)
  end

  def pre_execution_error(normalized_args)
    bound_tool_error_for_current_agent || tool_safety_error_for(:tool_arguments, normalized_args)
  end

  def complete_and_render(result)
    @context_wrapper.callback_manager.emit_tool_complete(@tool.name, result, @context_wrapper)
    Captain::ToolResult.render(result)
  end

  def bound_tool_error_for_current_agent
    return nil unless enforce_bound_tools?

    bound_ids = bound_tool_ids_for_current_agent
    return nil if bound_ids.include?(@tool.name.to_s)

    Captain::ToolResult.failure(error: TOOL_NOT_BOUND_ERROR, retryable: false)
  end

  def enforce_bound_tools?
    context = @context_wrapper.context
    ActiveModel::Type::Boolean.new.cast(context[:captain_v2_bound_tool_gate] || context['captain_v2_bound_tool_gate']) ||
      context.key?(:captain_v2_bound_tool_ids_by_agent) ||
      context.key?('captain_v2_bound_tool_ids_by_agent') ||
      context.key?(:captain_v2_bound_tool_ids) ||
      context.key?('captain_v2_bound_tool_ids')
  end

  def bound_tool_ids_for_current_agent
    context = @context_wrapper.context
    by_agent = bound_tool_ids_by_agent
    current_agent = context[:current_agent] || context['current_agent']
    return normalize_bound_tool_ids(by_agent[current_agent.to_s]) if current_agent.present? && by_agent.key?(current_agent.to_s)
    return [] if current_agent.present? && by_agent.present?

    normalize_bound_tool_ids(context[:captain_v2_bound_tool_ids] || context['captain_v2_bound_tool_ids'])
  end

  def bound_tool_ids_by_agent
    (context_wrapper_context[:captain_v2_bound_tool_ids_by_agent] ||
      context_wrapper_context['captain_v2_bound_tool_ids_by_agent'] ||
      {}).with_indifferent_access
  end

  def normalize_bound_tool_ids(bound_ids)
    Array(bound_ids).filter_map { |tool_id| tool_id.to_s.presence }
  end

  def context_wrapper_context
    @context_wrapper.context
  end

  def tool_safety_error_for(stage, content)
    case stage
    when :tool_arguments
      check_tool_arguments!(content)
    when :tool_results
      check_tool_results!(content)
    end

    nil
  rescue Llm::SafetyPolicy::UnsafeContentError, Llm::SafetyPolicy::UnavailableError => e
    Captain::ToolResult.failure(
      error: Captain::ToolSafety.blocked_message(stage: e.stage, error: e),
      retryable: false,
      audit: { failure_stage: e.stage.to_s, failure_reason: e.reason.to_s }
    )
  end

  def check_tool_arguments!(arguments)
    Captain::ToolSafety.check_arguments!(
      feature: :assistant,
      arguments: arguments,
      preferences: captain_runtime_preferences
    )
  end

  def check_tool_results!(result)
    Captain::ToolSafety.check_result!(
      feature: :assistant,
      result: result,
      preferences: captain_runtime_preferences
    )
  end

  def captain_runtime_preferences
    @context_wrapper.context.dig(:state, :captain_runtime)
  end

  def halt_result?(result)
    defined?(RubyLLM::Tool::Halt) && result.is_a?(RubyLLM::Tool::Halt)
  end

  def safety_checked_result(result)
    return result.content if halt_result?(result)

    result
  end
end
