module Captain::Tools::Instrumentation
  extend ActiveSupport::Concern
  include Integrations::LlmInstrumentation

  def execute(**args)
    unless Captain::ToolPolicy.runtime_allowed?(
      tool_definition,
      assistant: assistant,
      scope_name: tool_scope_name,
      user: @user
    )
      message = 'This tool is not available for the current assistant configuration.'
      audit_tool_execution(arguments: args, result: message)
      return message
    end

    instrument_tool_call(name, args) do
      result = super
      audit_tool_execution(arguments: args, result: result)
      result
    end
  rescue StandardError => e
    audit_tool_execution(arguments: args, error: e)
    raise
  end

  private

  def audit_tool_execution(arguments:, result: nil, error: nil)
    Captain::ToolExecutionAuditService.record(
      assistant: assistant,
      scope_name: tool_scope_name,
      tool_definition: tool_definition,
      arguments: arguments,
      result: result,
      error: error,
      user: @user,
      runtime_context: tool_runtime_context
    )
  end
end
