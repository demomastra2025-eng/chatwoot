class Crm::Appointments::AutomationState
  def self.explicit_actor?(actor)
    actor.present? || (defined?(Captain::Assistant) && Current.executed_by.is_a?(Captain::Assistant))
  end

  def self.manual_change!(deal)
    Crm::Appointments::DeliveryPolicy.stamp_in_memory!(deal)
    state = deal.appointment_automation_state.to_h
    state['manual_fingerprint'] = Crm::Appointments::Facts.new(deal: deal).fingerprint
    state['manual_changed_at'] = Time.current.iso8601(6)
    state['paused_at'] = Time.current.iso8601(6) if Crm::Appointments::Configuration.for(deal.pipeline)['manual_stage_change'] == 'pause'
    deal.appointment_automation_state = state
  end
end
