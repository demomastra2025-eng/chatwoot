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
