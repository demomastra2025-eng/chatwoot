class Integrations::Medelement::AppointmentProviderCommandReceiptService
  def initialize(appointment:, actor:, new_record:)
    @appointment = appointment
    @actor = actor
    @changed_attributes = appointment.saved_changes.except('updated_at')
    @event_name = resolve_event_name(new_record)
    @desired_attributes = Integrations::Medelement::OutboundChangeService.appointment_event_snapshot(appointment)
  end

  def perform
    return if appointment.medelement_provider_command_receipt.present?
    return unless provider_actor?

    attributes = provider_command_attributes
    command = Integrations::Medelement::OutboundChangeService.new(**attributes).perform || recent_command
    ensure_receipt_available!(command)
    attach_receipt!(command) if command.present?
    command
  rescue Scheduling::Error
    raise
  rescue StandardError => e
    Rails.logger.error("[AppointmentProviderCommandReceiptService] receipt creation failed: #{e.class}: #{e.message}")
    enqueue_retry!(attributes) if attributes.present?
    raise receipt_unavailable_error
  end

  private

  attr_reader :actor, :appointment, :changed_attributes, :desired_attributes, :event_name

  def resolve_event_name(new_record)
    return 'appointment_created' if new_record
    return 'appointment_cancelled' if appointment.status == 'cancelled' && changed_attributes.key?('status')

    'appointment_updated'
  end

  def attach_receipt!(command)
    appointment.reload
    appointment.medelement_provider_command_receipt = command
  end

  def ensure_receipt_available!(command)
    return if command.present? || !provider_confirmation_pending?

    raise receipt_unavailable_error
  end

  def provider_confirmation_pending?
    appointment.custom_attributes.to_h[Integrations::Medelement::AppointmentProviderStatus::ATTRIBUTE_KEY] ==
      Integrations::Medelement::AppointmentProviderStatus::PENDING
  end

  def recent_command
    Integrations::Medelement::ProviderCommand.where(
      account_id: appointment.account_id,
      appointment_id: appointment.id
    ).where('created_at >= ?', appointment.updated_at).order(created_at: :desc, id: :desc).first
  end

  def receipt_unavailable_error
    Scheduling::Error.new(
      code: 'MEDELEMENT_COMMAND_RECEIPT_UNAVAILABLE',
      message: 'Medelement command receipt is temporarily unavailable',
      status: :service_unavailable
    )
  end

  def provider_command_attributes
    {
      entity_type: 'appointment',
      entity_id: appointment.id,
      event_name: event_name,
      change: change_envelope,
      actor_id: user_actor&.id,
      actor_descriptor: { type: actor.class.base_class.name, id: actor.id },
      event_key: "onelink-event:#{event_fingerprint}"
    }
  end

  def change_envelope
    {
      account_id: appointment.account_id,
      payload_version: Integrations::Medelement::OutboundChangeJob::PAYLOAD_VERSION,
      changed_attributes: changed_attributes,
      desired_attributes: desired_attributes
    }
  end

  def event_fingerprint
    Integrations::Medelement::ProviderCommands::RequestSnapshotBuilder.fingerprint(
      'entity_type' => 'appointment',
      'entity_id' => appointment.id,
      'source_updated_at' => appointment.updated_at&.utc&.iso8601(6),
      'desired_attributes' => desired_attributes
    )
  end

  def provider_actor?
    return true if actor.is_a?(User)

    defined?(Captain::Assistant) && actor.is_a?(Captain::Assistant) && actor.account_id == appointment.account_id
  end

  def user_actor
    actor if actor.is_a?(User)
  end

  def enqueue_retry!(attributes)
    job_attributes = attributes.except(:actor_descriptor)
    job_attributes[:change] = attributes[:change].merge(actor_descriptor: attributes[:actor_descriptor])
    Integrations::Medelement::OutboundChangeJob.perform_later(**job_attributes)
  end
end
