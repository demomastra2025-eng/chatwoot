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

    result = @tool.execute(tool_context, **normalized_args)
    @context_wrapper.callback_manager.emit_tool_complete(@tool.name, result, @context_wrapper)
    result
  rescue StandardError => e
    @context_wrapper.callback_manager.emit_tool_complete(@tool.name, "ERROR: #{e.message}", @context_wrapper)
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
end
