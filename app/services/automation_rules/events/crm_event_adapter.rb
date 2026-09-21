class AutomationRules::Events::CrmEventAdapter
  PRODUCER = 'crm_event'.freeze

  def initialize(crm_event)
    @crm_event = crm_event
  end

  def capture!
    return unless supported_event?
    return if matching_snapshot.blank?

    AutomationRules::Events::CaptureService.capture!(
      account: crm_event.account,
      event_name: crm_event.event_type,
      subject: crm_event.eventable,
      payload_snapshot: matching_snapshot,
      changes_snapshot: crm_event.meta.to_h.with_indifferent_access[:changes].to_h,
      producer: PRODUCER,
      provenance: provenance,
      dedupe_key: "crm-event:#{crm_event.id}"
    )
  end

  private

  attr_reader :crm_event

  def supported_event?
    crm_event.event_type.in?(Crm::Event::SUPPORTED_AUTOMATION_EVENT_TYPES) &&
      crm_event.eventable.respond_to?(:automation_webhook_data)
  end

  def matching_snapshot
    crm_event.meta.to_h['automation_matching_snapshot']
  end

  def provenance
    {
      'source' => 'crm_event',
      'crm_event_id' => crm_event.id,
      'crm_source' => crm_event.source,
      'actor_kind' => crm_event.actor_kind,
      'actor_id' => crm_event.actor_id,
      'performed_by_type' => crm_event.performed_by_type,
      'performed_by_id' => crm_event.performed_by_id,
      'correlation_id' => crm_event.correlation_id,
      'crm_causation_id' => crm_event.causation_id
    }.compact
  end
end
