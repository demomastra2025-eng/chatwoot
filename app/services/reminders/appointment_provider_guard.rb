class Reminders::AppointmentProviderGuard
  CONTINUE = :continue
  STOP = :stop
  RETRY_DELAY = 5.minutes
  METADATA_KEY = 'medelement_provider_freshness'.freeze

  def initialize(reminder:, phase:)
    @reminder = reminder
    @phase = phase.to_s
  end

  def perform
    appointment = provider_appointment
    return CONTINUE if appointment.blank?
    return handle_cancellation_notification(appointment) if provider_cancellation_notification?(appointment)

    verification = Integrations::Medelement::AppointmentFreshnessVerifier.new(appointment: appointment).perform
    return CONTINUE if verification.allowed?

    verification.terminal? ? cancel!(verification) : defer!(verification)
    STOP
  end

  private

  attr_reader :reminder, :phase

  def provider_appointment
    return unless reminder.remindable_type == 'Scheduling::Appointment'

    reminder.remindable&.reload
  end

  def provider_cancellation_notification?(appointment)
    reminder.metadata.to_h[Reminder::AUTOMATION_EVENT_NAME_KEY] == 'appointment_cancelled' &&
      (appointment.source == 'medelement' || appointment.external_ref.to_s.start_with?('medelement:reception:'))
  end

  def handle_cancellation_notification(appointment)
    verification = cancellation_verification(appointment)
    return CONTINUE if verification.allowed?

    verification.terminal? ? cancel!(verification) : defer!(verification)
    STOP
  end

  def cancellation_verification(appointment)
    return cancellation_result('cancelled', 'cancellation_event_superseded') unless appointment.status == 'cancelled'

    command = cancellation_command(appointment)
    return cancellation_result('blocked', 'provider_remove_command_missing') if command.blank?
    return cancellation_result('cancelled', 'provider_remove_command_mismatch', command) unless trusted_cancellation_command?(command, appointment)
    return cancellation_result('fresh', nil, command) if command.succeeded?
    return cancellation_result('blocked', "provider_command_#{command.logical_status}", command) unless command.terminal?

    cancellation_result('cancelled', "provider_command_#{command.logical_status}", command)
  end

  def cancellation_command(appointment)
    command_id = appointment.custom_attributes.to_h[
      Integrations::Medelement::AppointmentProviderStatus::CANCELLATION_COMMAND_ID_KEY
    ]
    return if command_id.blank?

    Integrations::Medelement::ProviderCommand.find_by(
      id: command_id,
      account_id: appointment.account_id,
      appointment_id: appointment.id,
      operation: 'remove_reception'
    )
  end

  def trusted_cancellation_command?(command, appointment)
    reception_code = appointment.custom_attributes.to_h['medelement_reception_code'].presence ||
                     appointment.external_ref.to_s.delete_prefix('medelement:reception:').presence

    command.request_snapshot_valid? &&
      command.confirmation_matches_request_snapshot? &&
      command.provider_reception_code.to_s == reception_code.to_s &&
      command.request_snapshot['provider_reception_code'].to_s == reception_code.to_s
  end

  def cancellation_result(status, reason, command = nil)
    Integrations::Medelement::AppointmentFreshnessVerifier::Result.new(
      status: status,
      reason: reason,
      checked_at: Time.current,
      command_id: command&.id,
      command_status: command&.logical_status
    )
  end

  def cancel!(verification)
    reminder.with_lock do
      reminder.reload
      next unless guardable?

      reminder.update!(
        status: :cancelled,
        cancelled_at: Time.current,
        completed_at: nil,
        processing_started_at: nil,
        last_error: verification.reason,
        metadata: metadata(verification)
      )
    end
  end

  def defer!(verification)
    reminder.with_lock do
      reminder.reload
      next unless guardable?

      # This is a runtime retry, not a schedule-definition edit. Bypass relative schedule
      # rematerialization while still invalidating the current execution claim.
      # rubocop:disable Rails/SkipsModelValidations
      reminder.update_columns(
        status: Reminder.statuses.fetch('pending'),
        scheduled_at: Time.current + RETRY_DELAY,
        completed_at: nil,
        processing_started_at: nil,
        last_error: verification.reason,
        metadata: metadata(verification),
        schedule_revision: reminder.schedule_revision.to_i + 1,
        updated_at: Time.current
      )
      # rubocop:enable Rails/SkipsModelValidations
    end
  end

  def guardable?
    reminder.processing? || reminder.completed?
  end

  def metadata(verification)
    reminder.metadata.to_h.except(Reminder::PROCESSING_CLAIM_KEY).merge(
      METADATA_KEY => {
        'phase' => phase,
        'status' => verification.status,
        'reason' => verification.reason,
        'checked_at' => verification.checked_at.iso8601(6),
        'provider_command_id' => verification.command_id,
        'provider_command_status' => verification.command_status
      }.compact
    )
  end
end
