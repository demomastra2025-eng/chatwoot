class Crm::Appointments::DeliveryPolicy
  KEY = 'playground_run_policy'.freeze

  def self.current
    Current.playground_run_policy if Current.respond_to?(:playground_run_policy)
  end

  def self.stamp_in_memory!(deal)
    state = deal.appointment_automation_state.to_h.deep_dup
    current.nil? ? state.delete(KEY) : state[KEY] = current.deep_dup
    deal.appointment_automation_state = state
  end

  def self.stamp!(deal)
    deal.with_lock do
      return if deal.appointment_automation_state.to_h[KEY] == current

      stamp_in_memory!(deal)
      deal.save! if deal.changed?
    end
  end

  def self.with(deal)
    return yield unless defined?(Outbound::PlaygroundDeliveryPolicy)

    # A causal queued job keeps its original taint. A newly scheduled clock check reads the latest native state.
    cause = current
    policy = cause.nil? ? deal.appointment_automation_state.to_h[KEY] : cause
    Outbound::PlaygroundDeliveryPolicy.with(policy) { yield }
  end
end
