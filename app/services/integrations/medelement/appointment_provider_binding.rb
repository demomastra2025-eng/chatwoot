class Integrations::Medelement::AppointmentProviderBinding
  MEDELEMENT_SOURCE = 'medelement'.freeze

  def initialize(appointment:, reception:)
    @appointment = appointment
    @reception_code = reception.to_h['RECEPTION_CODE'].to_s
  end

  def validate!
    return true unless conflicting_source?
    return true if trusted_outbound?

    raise Scheduling::Error.new(
      code: 'DUPLICATE_EXTERNAL_REF',
      message: 'external_ref is already used by a non-Medelement appointment',
      status: :conflict
    )
  end

  def source
    return MEDELEMENT_SOURCE unless appointment.persisted?

    appointment.source.presence || MEDELEMENT_SOURCE
  end

  def source_mode
    appointment.persisted? && appointment.source != MEDELEMENT_SOURCE ? 'outbound' : 'imported'
  end

  private

  attr_reader :appointment, :reception_code

  def conflicting_source?
    appointment.persisted? && appointment.source.present? && appointment.source != MEDELEMENT_SOURCE
  end

  def trusted_outbound?
    return false if reception_code.blank?

    appointment.external_ref == expected_external_ref &&
      appointment.custom_attributes['medelement_reception_code'].to_s == reception_code &&
      appointment.custom_attributes['medelement_provider_sync_status'] == 'succeeded' &&
      succeeded_create_command?
  end

  def succeeded_create_command?
    Integrations::Medelement::ProviderCommand.exists?(
      appointment: appointment,
      operation: 'create_reception',
      status: 'succeeded'
    )
  end

  def expected_external_ref
    "medelement:reception:#{reception_code}"
  end
end
