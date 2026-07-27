class Integrations::Medelement::ProviderCommands::ReceptionPayloadBuilder
  def initialize(command:, configuration:)
    @command = command
    @configuration = configuration
  end

  def create_payload(patient_code:)
    payload = {
      patient_code: patient_code,
      specialist_code: specialist_code,
      company_cabinet_code: command.company_cabinet_code,
      starttime: provider_datetime(appointment.starts_at),
      endtime: provider_datetime(appointment.ends_at),
      description: appointment.client_comment.to_s.presence,
      color_code: 0
    }.compact
    service_code = appointment.service&.custom_attributes&.dig('medelement_nomenclature_code').presence
    payload[:nomenclature_code] = [service_code] if service_code.present?
    payload
  end

  def move_payload(patient_code:)
    {
      paient_code: patient_code,
      reception_code: command.provider_reception_code,
      doctor_code: specialist_code,
      start_time: provider_datetime(command.desired_starts_at),
      end_time: provider_datetime(command.desired_ends_at)
    }
  end

  private

  attr_reader :command, :configuration

  def appointment
    command.appointment
  end

  def specialist_code
    appointment.resource.custom_attributes.to_h.fetch('medelement_specialist_code')
  end

  def provider_datetime(value)
    value.in_time_zone(configuration.time_zone).strftime('%d.%m.%Y %H:%M')
  end
end
