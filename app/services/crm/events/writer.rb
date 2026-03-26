class Crm::Events::Writer
  def self.record!(account:, eventable:, actor:, event_type:, meta: {})
    account.crm_events.create!(
      eventable: eventable,
      actor: actor,
      event_type: event_type,
      meta: meta,
      created_at: Time.zone.now
    )
  end
end
