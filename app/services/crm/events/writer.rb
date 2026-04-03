class Crm::Events::Writer
  def self.record!(account:, eventable:, actor:, event_type:, meta: {})
    crm_event = account.crm_events.new(
      eventable: eventable,
      actor: actor,
      event_type: event_type,
      meta: meta,
      created_at: Time.zone.now
    )
    crm_event.performed_by = Current.executed_by
    crm_event.save!
    crm_event
  end
end
