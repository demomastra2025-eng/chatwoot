class Integrations::Medelement::ConflictEntityPresenter
  SPECIALIST_ENTITY_TYPES = %w[specialist cabinet specialist_service].freeze
  APPOINTMENT_ENTITY_TYPES = %w[appointment reception patient].freeze
  MIN_EPOCH = Time.utc(2000, 1, 1).to_i
  MAX_EPOCH = Time.utc(2100, 1, 1).to_i

  def initialize(conflict:, preloader: nil)
    @conflict = conflict
    @preloader = preloader
  end

  def payload
    return specialist_payload if SPECIALIST_ENTITY_TYPES.include?(conflict.entity_type)
    return appointment_payload if APPOINTMENT_ENTITY_TYPES.include?(conflict.entity_type)
  end

  private

  attr_reader :conflict, :preloader

  def specialist_payload
    resource = scoped_resource
    service = scoped_service
    details = conflict.details
    {
      kind: 'specialist',
      resource: resource_payload(resource),
      specialist_code: details['specialist_code'].presence || resource&.custom_attributes&.dig('medelement_specialist_code'),
      specialist_name: details['specialist_name'].presence || resource&.name,
      specialty: details['specialty'].presence || resource&.specialty,
      cabinet_code: details['cabinet_code'].presence,
      service_code: details['service_code'].presence,
      service: service_payload(service)
    }.compact
  end

  def appointment_payload
    appointment = scoped_appointment
    resource = appointment&.resource || scoped_resource
    details = conflict.details
    {
      kind: 'appointment',
      appointment: local_appointment_payload(appointment),
      resource: resource_payload(resource),
      reception_code: detail_or_value('reception_code', reception_code(appointment)),
      patient_code: details['patient_code'].presence,
      specialist_code: detail_or_value('specialist_code', appointment_specialist_code(appointment)),
      starts_at: appointment_time(appointment, :starts_at, 'starts_at_unix'),
      ends_at: appointment_time(appointment, :ends_at, 'ends_at_unix'),
      local_amount: details['local_amount'],
      provider_amount: details['provider_amount']
    }.compact
  end

  def detail_or_value(key, value)
    conflict.details[key].presence || value
  end

  def appointment_time(appointment, attribute, fallback_key)
    appointment&.public_send(attribute)&.iso8601 || unix_time(conflict.details[fallback_key])
  end

  def scoped_resource
    return preloader.resource_for(conflict.details) if preloader

    details = conflict.details
    return conflict.account.scheduling_resources.find_by(id: details['resource_id']) if details['resource_id'].present?
    return if details['specialist_code'].blank?

    conflict.account.scheduling_resources.find_by(
      "custom_attributes ->> 'medelement_specialist_code' = ?", details['specialist_code'].to_s
    )
  end

  def scoped_service
    return preloader.service_for(conflict.details) if preloader

    details = conflict.details
    return conflict.account.scheduling_services.find_by(id: details['service_id']) if details['service_id'].present?
    return if details['service_code'].blank?

    conflict.account.scheduling_services.find_by(
      "custom_attributes ->> 'medelement_nomenclature_code' = ?", details['service_code'].to_s
    )
  end

  def scoped_appointment
    return preloader.appointment_for(conflict.details) if preloader

    details = conflict.details
    return conflict.account.scheduling_appointments.find_by(id: details['appointment_id']) if details['appointment_id'].present?
    return if details['reception_code'].blank?

    conflict.account.scheduling_appointments.find_by(
      external_ref: "medelement:reception:#{details['reception_code']}"
    )
  end

  def resource_payload(resource)
    return if resource.blank?

    { id: resource.id, name: resource.name, specialty: resource.specialty, active: resource.active, timezone: resource.timezone }
  end

  def service_payload(service)
    return if service.blank?

    { id: service.id, name: service.name, active: service.active }
  end

  def local_appointment_payload(appointment)
    return if appointment.blank?

    {
      id: appointment.id,
      client_name: appointment.client_name,
      status: appointment.status,
      payment_status: appointment.payment_status,
      service_name: appointment.service_name_snapshot.presence || appointment.service&.name,
      resource_name: appointment.resource&.name,
      service_amount: appointment.service_amount,
      prepaid_amount: appointment.prepaid_amount,
      settlement_amount: appointment.settlement_amount
    }
  end

  def reception_code(appointment)
    appointment&.custom_attributes&.dig('medelement_reception_code')
  end

  def appointment_specialist_code(appointment)
    appointment&.custom_attributes&.dig('medelement_specialist_code')
  end

  def unix_time(value)
    epoch = Integer(value, exception: false)
    return unless epoch&.between?(MIN_EPOCH, MAX_EPOCH)

    Time.zone.at(epoch).iso8601
  end
end
