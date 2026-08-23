class MedelementOutboundChangeListener < BaseListener
  def appointment_created(event)
    enqueue_appointment(event)
  end

  def appointment_updated(event)
    enqueue_appointment(event)
  end

  def appointment_cancelled(event)
    enqueue_appointment(event)
  end

  def contact_created(event)
    enqueue_contact(event)
  end

  def contact_updated(event)
    enqueue_contact(event)
  end

  private

  def enqueue_contact(event)
    contact = event.data[:contact]
    performed_by = event.data[:performed_by]
    return if contact.blank? || !performed_by.is_a?(User)

    changed_attributes = event.data[:changed_attributes].to_h
    desired = event.data[:medelement_outbound_snapshot].presence ||
              Integrations::Medelement::OutboundChangeService.contact_event_snapshot(contact)
    enqueue_change(
      entity_type: 'contact',
      entity_id: contact.id,
      event_name: event.name,
      change: {
        changed_attributes: changed_attributes,
        desired_attributes: desired
      },
      actor_id: performed_by.id,
      event_key: event_key(event, 'contact', contact.id, desired)
    )
  end

  def enqueue_appointment(event)
    appointment = event.data[:appointment]
    performed_by = event.data[:performed_by]
    return if appointment.blank? || !performed_by.is_a?(User)

    changed_attributes = event.data[:changed_attributes].to_h
    desired = event.data[:medelement_outbound_snapshot].presence ||
              Integrations::Medelement::OutboundChangeService.appointment_event_snapshot(appointment)
    enqueue_change(
      entity_type: 'appointment',
      entity_id: appointment.id,
      event_name: event.name,
      change: {
        changed_attributes: changed_attributes,
        desired_attributes: desired
      },
      actor_id: performed_by.id,
      event_key: event_key(event, 'appointment', appointment.id, desired)
    )
  end

  def enqueue_change(**attributes)
    Integrations::Medelement::OutboundChangeJob.perform_later(**attributes)
  end

  def event_key(event, entity_type, entity_id, desired)
    fingerprint = Integrations::Medelement::ProviderCommands::RequestSnapshotBuilder.fingerprint(
      'event_name' => event.name.to_s,
      'event_timestamp' => event.timestamp&.utc&.iso8601(6),
      'entity_type' => entity_type,
      'entity_id' => entity_id,
      'desired_attributes' => desired
    )
    "onelink-event:#{fingerprint}"
  end
end
