class Integrations::Medelement::AppointmentImporterService
  MEDELEMENT_SOURCE = 'medelement'.freeze
  PRIMARY_APPOINTMENT_TYPE = 'primary'.freeze
  MIN_DURATION_MINUTES = 5
  RECONCILIATION_ATTRIBUTE_KEYS = %w[
    medelement_missing_since
    medelement_missing_syncs
    medelement_removed_at
  ].freeze

  def initialize(account:, conflict_tracker: nil)
    @account = account
    @conflict_tracker = conflict_tracker
  end

  def external_ref_for(reception_code)
    "medelement:reception:#{reception_code}"
  end

  def upsert!(resource:, contact:, reception:, import_context:)
    appointment = find_or_initialize_appointment(reception)
    unless appointment.persisted?
      return persist_appointment!(
        appointment,
        resource: resource,
        contact: contact,
        reception: reception,
        import_context: import_context
      )
    end

    appointment.with_lock do
      persist_appointment!(appointment, resource: resource, contact: contact, reception: reception, import_context: import_context)
    end
  end

  private

  attr_reader :account, :conflict_tracker

  def persist_appointment!(appointment, resource:, contact:, reception:, import_context:)
    ensure_medelement_source!(appointment)
    record_unresolved_patient_conflict(reception) if contact.blank?
    appointment.assign_attributes(
      appointment_attributes(
        appointment: appointment,
        resource: resource,
        contact: contact,
        reception: reception,
        import_context: import_context
      )
    )

    appointment.save! if appointment.new_record? || appointment.changed?
    appointment
  end

  # Keep the provider-to-appointment mapping visible as one declarative contract.
  # rubocop:disable Metrics/MethodLength
  def appointment_attributes(appointment:, resource:, contact:, reception:, import_context:)
    starts_at = import_context[:starts_at]
    ends_at = import_context[:ends_at]
    services, unresolved_service_codes = resolved_services(reception)

    base_attributes = {
      account: account,
      resource: resource,
      contact: contact,
      conversation: conversation_for_contact(appointment, contact),
      starts_at: starts_at,
      ends_at: ends_at,
      duration_min: duration_minutes(starts_at, ends_at),
      status: appointment_status(reception),
      appointment_type: PRIMARY_APPOINTMENT_TYPE,
      source: MEDELEMENT_SOURCE,
      service: services.first || appointment.service,
      service_name_snapshot: services.map(&:name).join(', ').presence || appointment.service_name_snapshot,
      custom_attributes: custom_attributes(
        appointment,
        reception,
        import_context,
        contact: contact,
        services: services,
        unresolved_service_codes: unresolved_service_codes
      )
    }

    base_attributes.merge(client_attributes(contact)).merge(financial_attributes(appointment, reception))
  end
  # rubocop:enable Metrics/MethodLength

  def appointment_status(reception)
    reception['ACTIVE'].to_i == 1 ? 'scheduled' : 'completed'
  end

  def client_attributes(contact)
    {
      client_name: client_name(contact),
      client_phone: contact_phone(contact),
      client_identifier: contact&.identifier.presence || contact&.custom_attributes&.dig('iin'),
      client_birth_date: contact&.custom_attributes&.dig('birth_date'),
      client_gender: contact&.custom_attributes&.dig('gender')
    }
  end

  def financial_attributes(appointment, reception)
    Integrations::Medelement::AppointmentFinancialReconciler.new(
      appointment: appointment,
      reception: reception,
      conflict_tracker: conflict_tracker
    ).attributes
  end

  def client_name(contact)
    contact&.name.presence || 'Unresolved MedElement patient'
  end

  def contact_phone(contact)
    return contact.phone_number if contact&.phone_number.present?

    conflict_comment = contact&.custom_attributes&.dig('phone_conflict_comment').to_s
    Array(contact&.custom_attributes&.dig('secondary_phones')).compact_blank.find do |phone|
      conflict_comment.blank? || conflict_comment.exclude?(phone)
    end
  end

  def conversation_for_contact(appointment, contact)
    conversation = appointment.conversation
    return conversation if conversation.blank?
    return conversation if contact.present? && conversation.contact_id == contact.id
  end

  def custom_attributes(appointment, reception, import_context, contact:, **service_data)
    services = service_data.fetch(:services)
    unresolved_service_codes = service_data.fetch(:unresolved_service_codes)
    attributes = appointment.custom_attributes.except(*RECONCILIATION_ATTRIBUTE_KEYS).merge(
      'medelement_cabinet_code' => reception['COMPANY_CABINET_CODE'].to_s.presence,
      'medelement_reception_code' => reception['RECEPTION_CODE'].to_s,
      'medelement_source_created_at' => reception['CREATED_AT'].to_s.presence,
      'medelement_specialist_code' => import_context[:specialist_code].to_s,
      'medelement_patient_unresolved' => contact.blank?,
      'source_mode' => 'imported'
    ).compact
    return attributes if Array(reception['SERVICES']).empty?

    attributes.merge(
      'service_ids' => services.map(&:id),
      'services' => services.map { |service| service.slice(:id, :name, :service_type, :duration_min) },
      'medelement_unresolved_service_codes' => unresolved_service_codes
    )
  end

  def resolved_services(reception)
    codes = reception_service_rows(reception).filter_map do |row|
      row['NOMENCLATURE_CODE'].to_s.presence
    end.uniq
    services_by_code = account.scheduling_services
                              .where("custom_attributes ->> 'medelement_nomenclature_code' IN (?)", codes)
                              .index_by { |service| service.custom_attributes['medelement_nomenclature_code'].to_s }

    [codes.filter_map { |code| services_by_code[code] }, codes.reject { |code| services_by_code.key?(code) }]
  end

  def reception_service_rows(reception)
    Array(reception['SERVICES']).select { |row| row.is_a?(Hash) }
  end

  def record_unresolved_patient_conflict(reception)
    conflict_tracker&.record!(
      phase: 'receptions',
      entity_type: 'patient',
      conflict_type: 'patient_unresolved',
      entity_key: reception['PATIENT_CODE'].presence || reception['RECEPTION_CODE'],
      severity: 'error',
      details: { reason: 'Provider patient could not be linked to a contact' }
    )
  end

  def duration_minutes(starts_at, ends_at)
    [((ends_at - starts_at) / 60).round, MIN_DURATION_MINUTES].max
  end

  def ensure_medelement_source!(appointment)
    return unless appointment.persisted? && appointment.source.present? && appointment.source != MEDELEMENT_SOURCE

    raise Scheduling::Error.new(
      code: 'DUPLICATE_EXTERNAL_REF',
      message: 'external_ref is already used by a non-Medelement appointment',
      status: :conflict
    )
  end

  def find_or_initialize_appointment(reception)
    account.scheduling_appointments.find_or_initialize_by(
      external_ref: external_ref_for(reception['RECEPTION_CODE'])
    )
  end
end
