class Scheduling::Appointments::AppointmentAccessGuard
  def initialize(appointment:, actor:, context:)
    @appointment = appointment
    @actor = actor
    @context = context&.to_h&.symbolize_keys
  end

  # The caller holds the appointment row lock. The token binds the exact
  # patient, resource and interval observed before requesting the mutation.
  def validate!
    return if @context.blank?
    unavailable! unless defined?(Captain::Assistant) && @actor.is_a?(Captain::Assistant) &&
                        @actor.account_id == @appointment.account_id && @context[:token].present?

    conversation = @actor.account.conversations.find_by(id: @context[:conversation_id])
    resolved = Captain::Tools::Agent::AppointmentAccess.resolve(
      token: @context[:token], assistant: @actor, conversation: conversation, appointment_id: @appointment.id
    )
    unavailable! unless resolved
    unavailable! if Captain::Tools::Agent::AppointmentAccess.other_patient?(@appointment, conversation) &&
                    @context[:patient_confirmed] != true
  end

  private

  def unavailable!
    raise Scheduling::Error.new(code: 'APPOINTMENT_ACCESS_CHANGED', message: 'Record is not available', status: :conflict)
  end
end
