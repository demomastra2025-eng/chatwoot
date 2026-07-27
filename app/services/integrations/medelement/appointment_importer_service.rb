class Integrations::Medelement::AppointmentImporterService
  MEDELEMENT_SOURCE = 'medelement'.freeze
  PRIMARY_APPOINTMENT_TYPE = 'primary'.freeze
  AWAITING_PAYMENT_STATUS = 'awaiting_payment'.freeze
  MIN_DURATION_MINUTES = 5
  RECONCILIATION_ATTRIBUTE_KEYS = %w[
    medelement_missing_since
    medelement_missing_syncs
    medelement_removed_at
  ].freeze

  def initialize(account:)
    @account = account
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

  attr_reader :account

  def persist_appointment!(appointment, resource:, contact:, reception:, import_context:)
    ensure_medelement_source!(appointment)
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

  def appointment_attributes(appointment:, resource:, contact:, reception:, import_context:)
    starts_at = import_context[:starts_at]
    ends_at = import_context[:ends_at]

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
      custom_attributes: custom_attributes(appointment, reception, import_context)
    }

    base_attributes.merge(client_attributes(contact, reception)).merge(financial_attributes)
  end

  def appointment_status(reception)
    reception['ACTIVE'].to_i == 1 ? 'scheduled' : 'completed'
  end

  def client_attributes(contact, reception)
    {
      client_name: client_name(contact, reception),
      client_phone: contact_phone(contact),
      client_identifier: contact&.identifier.presence || contact&.custom_attributes&.dig('iin'),
      client_birth_date: contact&.custom_attributes&.dig('birth_date'),
      client_gender: contact&.custom_attributes&.dig('gender')
    }
  end

  def financial_attributes
    {
      service_amount: 0,
      prepaid_amount: 0,
      settlement_amount: 0,
      payment_status: AWAITING_PAYMENT_STATUS
    }
  end

  def client_name(contact, reception)
    contact&.name.presence || "Patient #{reception['PATIENT_CODE']}"
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

  def custom_attributes(appointment, reception, import_context)
    appointment.custom_attributes.except(*RECONCILIATION_ATTRIBUTE_KEYS).merge(
      'medelement_cabinet_code' => reception['COMPANY_CABINET_CODE'].to_s.presence,
      'medelement_patient_code' => reception['PATIENT_CODE'].to_s.presence,
      'medelement_reception_code' => reception['RECEPTION_CODE'].to_s,
      'medelement_source_created_at' => reception['CREATED_AT'].to_s.presence,
      'medelement_specialist_code' => import_context[:specialist_code].to_s,
      'source_mode' => 'imported'
    ).compact
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
