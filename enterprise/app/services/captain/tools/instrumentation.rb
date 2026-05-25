module Captain::Tools::Instrumentation
  extend ActiveSupport::Concern
  include Integrations::LlmInstrumentation

  def execute(**args)
    instrument_tool_call(name, tool_trace_arguments(args), tool_instrumentation_params(args)) do
      confirmation_result = enforce_tool_confirmation(args)
      if confirmation_result.present?
        audit_tool_execution(arguments: args, result: confirmation_result)
        return confirmation_result
      end

      Captain::ToolSafety.check_arguments!(
        feature: tool_safety_feature,
        arguments: args,
        account: tool_safety_account,
        preferences: tool_safety_preferences
      )
      result = super
      Captain::ToolSafety.check_result!(
        feature: tool_safety_feature,
        result: result,
        account: tool_safety_account,
        preferences: tool_safety_preferences
      )
      audit_tool_execution(arguments: args, result: result)
      result
    rescue Llm::SafetyPolicy::UnsafeContentError, Llm::SafetyPolicy::UnavailableError => e
      message = tool_failure(Captain::ToolSafety.blocked_message(stage: e.stage, error: e))
      audit_tool_execution(arguments: args, result: message, error: e)
      message
    end
  rescue StandardError => e
    audit_tool_execution(arguments: args, error: e)
    raise
  end

  private

  def tool_trace_arguments(arguments)
    Captain::ToolTraceRedactor.call(arguments)
  end

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

  def enforce_tool_confirmation(arguments)
    return unless tool_scope_name == Captain::ToolAccess::SCOPE_ASSISTANT
    return inactive_tool_result unless active?

    Captain::Copilot::ToolConfirmationGate.new(
      copilot_thread: @copilot_thread,
      tool_definition: tool_definition,
      arguments: arguments,
      user: @user
    ).call
  end

  def inactive_tool_result
    message = account_administrator? ? 'Tool is not available for the current operator' : 'Account administrator permission is required'
    tool_failure(ArgumentError.new(message))
  end

  def tool_instrumentation_params(arguments)
    {
      account: tool_safety_account,
      account_id: tool_safety_account&.id,
      conversation_id: @conversation&.id,
      feature_name: tool_safety_feature,
      trace_preferences: tool_safety_preferences,
      metadata: {
        assistant_id: assistant&.id,
        tool_name: name,
        tool_scope: tool_scope_name,
        tool_definition_id: tool_definition[:id],
        argument_keys: arguments.keys.sort.join(',')
      }.compact
    }
  end
end
