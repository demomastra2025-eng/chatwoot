class Scheduling::Appointments::ProviderCancellationPolicy
  STATUS = Integrations::Medelement::AppointmentProviderStatus
  RECEPTION_PREFIX = 'medelement:reception:'.freeze

  def initialize(appointment:)
    @appointment = appointment
  end

  def provider_related?
    return true if appointment.source == Scheduling::Appointments::MutationGuard::PROVIDER_SOURCE

    attrs = appointment.custom_attributes.to_h
    attrs[STATUS::ATTRIBUTE_KEY].present? || attrs['medelement_reception_code'].present? ||
      appointment.external_ref.to_s.start_with?(RECEPTION_PREFIX) || unfinished_create_command? || create_write_started?
  end

  def confirmed_for_removal?
    return false unless confirmed_status?
    return false unless Integrations::Medelement::ProviderCommands::ReceptionVerifier.valid_reception_code?(reception_code)
    return false if appointment.contact.blank? || unfinished_create_command? || unfinished_remove_command?

    true
  end

  def removal_unresolved?
    return unfinished_create_command? || unfinished_remove_command? if appointment.status == 'cancelled'

    attrs = appointment.custom_attributes.to_h
    (attrs[STATUS::CANCELLATION_COMMAND_ID_KEY].present? && attrs[STATUS::ATTRIBUTE_KEY] != STATUS::SUCCEEDED) ||
      unfinished_remove_command?
  end

  def manually_resolved?
    appointment.custom_attributes.to_h[
      Integrations::Medelement::ProviderCommands::ManualCancellationResolutionService::VERIFIED_AT_KEY
    ].present?
  end

  def ensure_deletable!
    if removal_unresolved? || manually_resolved?
      raise Scheduling::Error.new(
        code: 'MEDELEMENT_CANCELLATION_RECORD_PROTECTED',
        message: 'The Medelement cancellation record must be retained for verification and synchronization',
        status: :conflict
      )
    end
    return if appointment.status == 'cancelled'

    raise Scheduling::Error.new(
      code: 'APPOINTMENT_DELETE_REQUIRES_CANCELLED',
      message: 'Only cancelled appointments can be deleted',
      status: :unprocessable_content
    )
  end

  private

  attr_reader :appointment

  def imported?
    appointment.source == Scheduling::Appointments::MutationGuard::PROVIDER_SOURCE
  end

  def confirmed_status?
    status = appointment.custom_attributes.to_h[STATUS::ATTRIBUTE_KEY]
    status == STATUS::SUCCEEDED || (status.blank? && imported?) || retryable_prewrite_removal?(status)
  end

  def reception_code
    attrs = appointment.custom_attributes.to_h
    return attrs['medelement_reception_code'].presence if attrs['medelement_reception_code'].present?
    return unless appointment.external_ref.to_s.start_with?(RECEPTION_PREFIX)

    appointment.external_ref.delete_prefix(RECEPTION_PREFIX)
  end

  def unfinished_create_command?
    command_scope.where(operation: 'create_reception').unfinished.exists?
  end

  def create_write_started?
    command_scope.where(operation: 'create_reception')
                 .where("execution_state ->> 'write_phase' = 'reception_create'").exists?
  end

  def unfinished_remove_command?
    command_scope.where(operation: 'remove_reception').unfinished.exists?
  end

  def retryable_prewrite_removal?(status)
    return false unless status.in?([STATUS::PENDING, STATUS::FAILED])

    last = command_scope.where(operation: 'remove_reception').order(id: :desc).first
    last&.status == 'failed' && last.execution_state.to_h['write_phase'].blank?
  end

  def command_scope
    Integrations::Medelement::ProviderCommand.where(account_id: appointment.account_id, appointment_id: appointment.id)
  end
end
