class Captain::Playground::ExternalToolPolicy
  REASON = 'unsupported_external_tool_in_playground'.freeze
  MESSAGE = 'External tools are blocked in Playground because their delivery target cannot be verified'.freeze

  class Blocked < Outbound::PlaygroundDeliveryPolicy::Blocked; end

  def self.failure_if_tainted(state: nil)
    failure if tainted?(state)
  end

  def self.ensure_allowed!(state: nil)
    raise Blocked, "#{REASON}: #{MESSAGE}" if tainted?(state)
  end

  def self.failure
    Captain::ToolResult.failure(
      error: MESSAGE, retryable: false,
      data: { code: REASON, reason: REASON, blocked: true, delivered: false },
      audit: { failure_stage: 'playground_policy', failure_reason: REASON, provider_call_blocked: true }
    )
  end

  def self.tainted?(state)
    return true unless Current.playground_run_policy.nil?

    state = state.to_h.with_indifferent_access
    return true if state[:source].to_s == 'playground' || state[:playground].present?

    %i[conversation contact].any? do |key|
      record = state[key]
      next false unless record.is_a?(Hash)

      attributes = record[:additional_attributes]
      attributes.is_a?(Hash) &&
        (attributes.key?('captain_playground_source') || attributes.key?(Outbound::PlaygroundDeliveryPolicy::ATTRIBUTE_KEY))
    end
  end
end
