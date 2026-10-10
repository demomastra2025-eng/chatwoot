# Cancels a MedElement-linked appointment inside OneLink only, used while the hook setting
# `remove_reception_on_cancel` is off: no provider command is created and MedElement is never called.
# The reception stays active in MedElement; the marker keeps sync from re-opening the appointment and
# lets the UI warn that the doctor's time must be freed in MedElement manually.
class Scheduling::Appointments::ProviderLocalCancellationService
  LOCAL_CANCELLATION = Integrations::Medelement::LocalCancellation

  def initialize(appointment:, actor:)
    @appointment = appointment
    @actor = actor
  end

  # The caller holds the appointment row lock (CancelService#perform).
  def perform
    with_actor_context do
      ApplicationRecord.transaction do
        ensure_no_provider_command_in_progress!
        cancel_locally!
        cancel_related_touches!
        Scheduling::Appointments::FinanceSyncService.new(appointment: appointment, actor: user_actor).sync!
      end
    end
    appointment.reload
  end

  private

  attr_reader :actor, :appointment

  def ensure_no_provider_command_in_progress!
    commands = Integrations::Medelement::ProviderCommand.where(account_id: appointment.account_id, appointment_id: appointment.id)
    return unless commands.unfinished.exists?

    raise Scheduling::Error.new(
      code: 'MEDELEMENT_BOOKING_REQUIRES_VERIFICATION',
      message: 'A Medelement command for this appointment is still in progress',
      status: :conflict
    )
  end

  def cancel_locally!
    attributes = Scheduling::Appointments::PlaygroundRunStamp.apply(appointment.custom_attributes)
    attributes = attributes.merge(LOCAL_CANCELLATION::MARKER_KEY => LOCAL_CANCELLATION.marker(appointment, actor))
    # Keeps the MedElement outbound listener away from this change: nothing may be sent for it.
    appointment.mark_medelement_provider_reconciled!
    appointment.update!(status: 'cancelled', payment_status: 'cancelled', custom_attributes: attributes)
  end

  def cancel_related_touches!
    Reminders::BulkCancelService.new(
      account: appointment.account,
      remindable: appointment,
      actor: actor,
      reason: 'отменен из-за отмены записи',
      metadata: { cancelled_via: 'appointment_cancelled' }
    ).perform
  end

  def user_actor
    actor if actor.is_a?(User)
  end

  def with_actor_context
    previous_actor = Current.executed_by
    Current.executed_by = actor if actor.present?
    yield
  ensure
    Current.executed_by = previous_actor
  end
end
