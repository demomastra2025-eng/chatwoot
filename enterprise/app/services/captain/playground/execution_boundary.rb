class Captain::Playground::ExecutionBoundary
  def self.execute(tool, tool_context, arguments)
    state = tool_context.state.with_indifferent_access
    session = tool_context.context[:playground_session]
    return yield unless state[:source] == 'playground' || state[:playground].present? || session
    return failure('A server-owned Playground session is required') unless session.is_a?(Captain::Playground::Session)

    session.assert_context!(state)
    return yield if tool.is_a?(Captain::Runtime::HandoffTool)
    return Captain::Playground::ToolExecutor.new(session).execute(tool.name, arguments, context: tool_context) if session.trial?

    reject_trial_handles!(arguments)
    return failure(Outbound::PlaygroundDeliveryPolicy::BLOCKED_MESSAGE) if tool.name.to_s == 'send_notification'
    if %w[send_message_to_conversation retry_failed_message].include?(tool.name.to_s)
      Outbound::PlaygroundDeliveryPolicy.ensure!(conversation: session.conversation, policy: session.run_policy)
    end
    Outbound::PlaygroundDeliveryPolicy.with(session.run_policy) { yield }
  rescue ArgumentError, Outbound::PlaygroundDeliveryPolicy::Blocked => e
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
end
