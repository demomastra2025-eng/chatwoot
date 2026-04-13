# frozen_string_literal: true

class Captain::Runtime::ToolWrapper
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

    argument_error = tool_safety_error_for(:tool_arguments, normalized_args)
    if argument_error
      @context_wrapper.callback_manager.emit_tool_complete(@tool.name, argument_error, @context_wrapper)
      return Captain::ToolResult.render(argument_error)
    end

    result = @tool.execute(tool_context, **normalized_args)
    result_error = tool_safety_error_for(:tool_results, result)
    final_result = result_error || result
    @context_wrapper.callback_manager.emit_tool_complete(@tool.name, final_result, @context_wrapper)
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
    return args.transform_keys(&:to_sym) if args.respond_to?(:transform_keys)

    {}
  end

  def tool_safety_error_for(stage, content)
    case stage
    when :tool_arguments
      Captain::ToolSafety.check_arguments!(
        feature: :assistant,
        arguments: content,
        preferences: @context_wrapper.context.dig(:state, :captain_runtime)
      )
    when :tool_results
      Captain::ToolSafety.check_result!(
        feature: :assistant,
        result: content,
        preferences: @context_wrapper.context.dig(:state, :captain_runtime)
      )
    end

    nil
  rescue Llm::SafetyPolicy::UnsafeContentError, Llm::SafetyPolicy::UnavailableError => e
    Captain::ToolResult.failure(
      error: Captain::ToolSafety.blocked_message(stage: e.stage, error: e),
      retryable: false,
      audit: { failure_stage: e.stage.to_s, failure_reason: e.reason.to_s }
    )
  end
end
