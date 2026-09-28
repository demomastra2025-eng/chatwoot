class Scheduling::Appointments::CancelService
  PROVIDER_UNAVAILABLE_CODE = 'MEDELEMENT_CANCELLATION_UNAVAILABLE'.freeze
  PROVIDER_SYNC_STATUS_KEY = Integrations::Medelement::AppointmentProviderStatus::ATTRIBUTE_KEY

  def initialize(appointment:, actor:)
    @appointment = appointment
    @actor = actor
  end

  def perform
    appointment.with_lock do
      return normalize_cancelled_payment! if appointment.status == 'cancelled'
      return cancel_provider_appointment! if provider_cancellation_policy.provider_related?

      Scheduling::Appointments::UpsertService.new(
        account: appointment.account,
        appointment: appointment,
        params: { status: 'cancelled', payment_status: 'cancelled' },
        actor: actor
      ).perform
    end
  end

  private

  attr_reader :actor, :appointment

  def provider_cancellation_policy
    Scheduling::Appointments::ProviderCancellationPolicy.new(appointment: appointment)
  end

  def normalize_cancelled_payment!
    return appointment if appointment.payment_status == 'cancelled'

    appointment.update!(payment_status: 'cancelled')
    appointment
  end

  def cancel_provider_appointment!
    raise booking_requires_verification_error unless provider_cancellation_policy.confirmed_for_removal?

    command = Integrations::Medelement::OutboundChangeService.new(**provider_removal_attributes).perform
    raise provider_cancellation_unavailable_error if command.blank?

    appointment.reload
    appointment.medelement_provider_command_receipt = command
    appointment
  end

  def provider_removal_attributes
    {
      entity_type: 'appointment',
      entity_id: appointment.id,
      account_id: appointment.account_id,
      event_name: 'appointment_cancelled',
      actor_id: user_actor&.id,
      actor_descriptor: non_user_actor_descriptor,
      event_key: provider_cancellation_event_key,
      change: {
        account_id: appointment.account_id,
        payload_version: Integrations::Medelement::OutboundChangeJob::PAYLOAD_VERSION,
        changed_attributes: provider_changed_attributes,
        desired_attributes: provider_desired_attributes
      }
    }
  end

  def user_actor
    actor if actor.is_a?(User)
  end

  # Captain cancels on the patient's behalf: the command records the assistant
  # as its requester instead of resolving its id against account users.
  def non_user_actor_descriptor
    return if actor.blank? || actor.is_a?(User)

    { type: actor.class.base_class.name, id: actor.id }
  end

  def booking_requires_verification_error
    Scheduling::Error.new(
      code: 'MEDELEMENT_BOOKING_REQUIRES_VERIFICATION',
      message: 'Medelement reception must be verified before cancellation',
      status: :conflict
    )
  end

  def provider_changed_attributes
    {
      'status' => [appointment.status, 'cancelled'],
      'payment_status' => [appointment.payment_status, 'cancelled']
    }
  end

  def provider_desired_attributes
    Integrations::Medelement::OutboundChangeService
      .appointment_event_snapshot(appointment)
      .merge('status' => 'cancelled')
      .tap do |attributes|
        attributes['custom_attributes'] = attributes.fetch('custom_attributes', {}).except(PROVIDER_SYNC_STATUS_KEY)
      end
  end

  def provider_cancellation_event_key
    provider_reference = appointment.custom_attributes.to_h['medelement_reception_code'].presence || appointment.external_ref
    retry_reference = latest_unsuccessful_provider_cancellation_id
    ["scheduling-appointment-cancel:#{appointment.id}:#{provider_reference}", retry_reference].compact.join(':retry:')
  end

  def latest_unsuccessful_provider_cancellation_id
    Integrations::Medelement::ProviderCommand
      .where(
        account_id: appointment.account_id,
        appointment_id: appointment.id,
        operation: 'remove_reception',
        status: %w[failed declined cancelled]
      )
      .maximum(:id)
  end

  def provider_cancellation_unavailable_error
    Scheduling::Error.new(
      code: PROVIDER_UNAVAILABLE_CODE,
      message: 'Medelement cancellation could not be queued',
      status: :unprocessable_content
    )
  end
end
