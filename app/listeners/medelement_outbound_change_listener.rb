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
        desired_attributes: desired,
        account_id: contact.account_id,
        payload_version: Integrations::Medelement::OutboundChangeJob::PAYLOAD_VERSION
      },
      actor_id: performed_by.id,
      event_key: event_key(event, 'contact', contact.id, desired)
    )
  end

  def enqueue_appointment(event)
    appointment = event.data[:appointment]
    performed_by = event.data[:performed_by]
    return unless appointment_event_outbound?(event, appointment, performed_by)

    attributes = appointment_change_attributes(event, appointment, performed_by)
    command = Integrations::Medelement::OutboundChangeService.new(**attributes).perform
    appointment.medelement_provider_command_receipt = command if command.present?
  rescue StandardError => e
    Rails.logger.error("[MedelementOutboundChangeListener] command receipt creation failed: #{e.class}")
    enqueue_change(**attributes) if attributes.present?
  end

  def appointment_change_attributes(event, appointment, performed_by)
    desired = event.data[:medelement_outbound_snapshot].presence || appointment_snapshot(appointment)
    {
      entity_type: 'appointment',
      entity_id: appointment.id,
      event_name: event.name,
      change: {
        changed_attributes: event.data[:changed_attributes].to_h,
        desired_attributes: desired,
        account_id: appointment.account_id,
        payload_version: Integrations::Medelement::OutboundChangeJob::PAYLOAD_VERSION
      },
      actor_id: outbound_actor_id(performed_by),
      actor_descriptor: actor_descriptor(performed_by),
      event_key: event_key(event, 'appointment', appointment.id, desired)
    }
  end

  def appointment_snapshot(appointment)
    Integrations::Medelement::OutboundChangeService.appointment_event_snapshot(appointment)
  end

  def appointment_event_outbound?(event, appointment, actor)
    !event.data[:medelement_provider_reconciled] && appointment.present? && appointment_outbound_actor?(actor, appointment)
  end

  def appointment_outbound_actor?(actor, appointment)
    return true if actor.is_a?(User)

    defined?(Captain::Assistant) && actor.is_a?(Captain::Assistant) && actor.account_id == appointment.account_id
  end

  def outbound_actor_id(actor)
    actor.id if actor.is_a?(User)
  end

  def actor_descriptor(actor)
    { type: actor.class.base_class.name, id: actor.id }
  end

  def enqueue_change(**attributes)
    actor = attributes.delete(:actor_descriptor)
    attributes[:change] = attributes[:change].to_h.merge(actor_descriptor: actor) if actor.present?
    Integrations::Medelement::OutboundChangeJob.perform_later(**attributes)
  end

  def event_key(event, entity_type, entity_id, desired)
    fingerprint = Integrations::Medelement::ProviderCommands::RequestSnapshotBuilder.fingerprint(
      'entity_type' => entity_type,
      'entity_id' => entity_id,
      'source_updated_at' => event.data[:medelement_source_updated_at].presence || event.timestamp&.utc&.iso8601(6),
      'desired_attributes' => desired
    )
    "onelink-event:#{fingerprint}"
  end
end
