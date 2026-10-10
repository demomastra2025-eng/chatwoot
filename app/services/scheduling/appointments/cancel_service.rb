class Scheduling::Appointments::CancelService
  PROVIDER_UNAVAILABLE_CODE = 'MEDELEMENT_CANCELLATION_UNAVAILABLE'.freeze
  PROVIDER_SYNC_STATUS_KEY = Integrations::Medelement::AppointmentProviderStatus::ATTRIBUTE_KEY

  def initialize(appointment:, actor:, expected_medelement_cancellation_mode: nil, appointment_access: nil)
    @appointment = appointment
    @actor = actor
    @expected_medelement_cancellation_mode = expected_medelement_cancellation_mode
    @appointment_access = appointment_access
  end

  def perform
    appointment.with_lock do
      Scheduling::Appointments::AppointmentAccessGuard.new(
        appointment: appointment, actor: actor, context: appointment_access
      ).validate!
      if defined?(Captain::Assistant) && actor.is_a?(Captain::Assistant)
        Scheduling::Appointments::MutationGuard.ensure_editable!(appointment)
      end
      cancellation_mode = cancellation_mode_for_locked_appointment
      return normalize_cancelled_payment! if appointment.status == 'cancelled'
      return cancel_provider_linked_appointment!(cancellation_mode) if provider_cancellation_policy.provider_related?

      Scheduling::Appointments::UpsertService.new(
        account: appointment.account,
        appointment: appointment,
        params: { status: 'cancelled', payment_status: 'cancelled' },
        actor: actor
      ).perform
    end
  end

  private

  attr_reader :actor, :appointment, :expected_medelement_cancellation_mode, :appointment_access

  def provider_cancellation_policy
    Scheduling::Appointments::ProviderCancellationPolicy.new(appointment: appointment)
  end

  def cancellation_mode_for_locked_appointment
    current_mode = Integrations::Medelement::LocalCancellation.cancellation_mode(appointment)
    raise booking_requires_verification_error if unverified_provider_creation?(current_mode)

    resolved_medelement_cancellation_mode(current_mode)
  end

  def cancellation_mode_changed?(current_mode)
    expected_medelement_cancellation_mode.present? && current_mode.present? &&
      current_mode != expected_medelement_cancellation_mode
  end

  def unverified_provider_creation?(current_mode)
    return false if appointment.status == 'cancelled' || cancellation_mode_changed?(current_mode)

    policy = provider_cancellation_policy
    policy.provider_creation_unresolved? && !policy.confirmed_for_removal?
  end

  def resolved_medelement_cancellation_mode(current_mode)
    return current_mode if expected_medelement_cancellation_mode.blank? || current_mode == expected_medelement_cancellation_mode

    raise Scheduling::Error.new(
      code: 'MEDELEMENT_CANCELLATION_MODE_CHANGED',
      message: 'Medelement cancellation settings changed. Review the current cancellation mode before retrying.',
      status: :conflict
    )
  end

  def normalize_cancelled_payment!
    return appointment if appointment.payment_status == 'cancelled'

    appointment.update!(payment_status: 'cancelled', custom_attributes: stamped_custom_attributes)
    appointment
  end

  # The hook setting remove_reception_on_cancel decides: off (default) keeps the MedElement reception and
  # cancels only in OneLink; on removes the reception through the confirmed provider command flow.
  def cancel_provider_linked_appointment!(cancellation_mode)
    # Use the mode checked under the appointment lock; a settings change during this request cannot
    # turn a local-only confirmation into a provider removal.
    if cancellation_mode == Integrations::Medelement::LocalCancellation::MODE_LOCAL_ONLY
      return Scheduling::Appointments::ProviderLocalCancellationService.new(appointment: appointment, actor: actor).perform
    end

    cancel_provider_appointment!
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
        attributes['custom_attributes'] = Scheduling::Appointments::PlaygroundRunStamp
                                          .apply(attributes.fetch('custom_attributes', {})).except(PROVIDER_SYNC_STATUS_KEY)
      end
  end

  def stamped_custom_attributes
    Scheduling::Appointments::PlaygroundRunStamp.apply(appointment.custom_attributes)
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
