class Captain::Playground::ExecutionBoundary
  def self.execute(tool, tool_context, arguments, &)
    state = tool_context.state.with_indifferent_access
    session = tool_context.context[:playground_session]
    tainted = Captain::Playground::ExternalToolPolicy.tainted?(state)
    return failure('Legacy Playground execution is blocked; reset the session') if tainted && !session && !opaque_external_tool?(tool)
    unless state[:source] == 'playground' || state[:playground].present? || session
      blocked = Captain::Playground::ExternalToolPolicy.failure_if_tainted(state: state) if opaque_external_tool?(tool)
      return blocked if blocked

      return yield
    end
    return failure('A server-owned Playground session is required') unless session.is_a?(Captain::Playground::Session)

    session.assert_context!(state)
    return yield if tool.is_a?(Captain::Runtime::HandoffTool)
    return Captain::Playground::ExternalToolPolicy.failure if opaque_external_tool?(tool)
    return Captain::Playground::ToolSupport.failure(tool.name) if Captain::Playground::ToolSupport::EXTERNAL_TOOLS.include?(tool.name.to_s)

    executor = Captain::Playground::RealToolExecutor.new(session)
    if executor.synthetic?(tool.name.to_s, arguments)
      return Captain::Playground::ToolExecutor.new(session).execute(tool.name, arguments, context: tool_context)
    end
    return executor.execute(tool.name.to_s, arguments) if executor.read?(tool.name.to_s)

    preview = Captain::Playground::ActionApproval.new(session).preview(tool.name.to_s, arguments)
    Captain::ToolResult.failure(error: 'Review and confirm this exact real action in Playground', retryable: false,
                                data: { code: 'playground_confirmation_required', action_id: preview['id'], delivered: false })
  rescue ArgumentError, Pundit::NotAuthorizedError, ActiveRecord::RecordNotFound, Outbound::PlaygroundDeliveryPolicy::Blocked => e
    failure(e.message)
  end

  def self.reject_trial_handles!(value)
    case value
    when Hash then value.each_value { |item| reject_trial_handles!(item) }
    when Array then value.each { |item| reject_trial_handles!(item) }
    when String
      raise ArgumentError, 'Trial references cannot be used in Live Playground' if value.start_with?('trial_')
    end
  end

  def self.failure(message)
    Captain::ToolResult.failure(error: message, data: { code: 'playground_policy_blocked', delivered: false }, retryable: false)
  end

  def self.opaque_external_tool?(tool)
    tool.is_a?(Captain::Tools::HttpTool) || tool.is_a?(Captain::Tools::McpTool) || tool.is_a?(Captain::Tools::SkillScriptTool)
  end
end
