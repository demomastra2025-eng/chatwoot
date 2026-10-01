module Integrations::Medelement::AppointmentPatientIdentity
  EXPLICIT_IDENTIFIER_KEY = 'medelement_client_identifier_explicit'.freeze
  OWNED_IDENTITY_KEY = 'medelement_appointment_patient_identity'.freeze
  SNAPSHOT_KEY = 'appointment_patient_identity'.freeze
  BINDING_KEY = 'patient_contact_id'.freeze
  NAME_KEYS = %w[first_name last_name middle_name].freeze
  FIELDS = %w[client_first_name client_last_name client_middle_name client_identifier client_birth_date client_gender client_phone].freeze

  module_function

  def owned?(attributes)
    attributes.to_h[OWNED_IDENTITY_KEY] == true
  end

  def explicit_identifier?(attributes)
    attributes.to_h[EXPLICIT_IDENTIFIER_KEY] == true
  end

  def marked?(attributes)
    owned?(attributes) || explicit_identifier?(attributes)
  end

  def provider_code(appointment:, contact:)
    attributes = appointment&.custom_attributes.to_h
    own_code = attributes['medelement_patient_code'].presence ||
               appointment&.patient_contact&.custom_attributes.to_h['medelement_patient_code'].presence
    return own_code if owned?(attributes)

    contact&.custom_attributes.to_h['medelement_patient_code'].presence || own_code
  end

  def frozen?(snapshot)
    snapshot.key?(SNAPSHOT_KEY)
  end

  def snapshot(attributes:, values:)
    {
      'owned' => owned?(attributes),
      'explicit_identifier' => explicit_identifier?(attributes),
      'fields' => FIELDS.index_with { |key| normalize(key, values.fetch(key)) }
    }
  end

  def current_snapshot(appointment)
    snapshot(attributes: appointment.custom_attributes, values: FIELDS.index_with { |key| appointment.public_send(key) })
  end

  def current?(command)
    return false unless binding_current?(command)
    return !marked?(command.appointment&.custom_attributes) unless frozen?(command.request_snapshot)
    return false unless command.appointment

    current_snapshot(command.appointment) == command.request_snapshot[SNAPSHOT_KEY]
  end

  def ensure_write_target_unchanged!(appointment)
    return unless appointment.persisted?

    previous = snapshot(attributes: appointment.custom_attributes_in_database,
                        values: FIELDS.index_with { |key| appointment.attribute_in_database(key) })
    return if current_snapshot(appointment) == previous && appointment.patient_contact_id == appointment.attribute_in_database('patient_contact_id')

    commands = Integrations::Medelement::ProviderCommand.where(account_id: appointment.account_id, appointment_id: appointment.id)
                                                        .where("NULLIF(execution_state ->> 'write_phase', '') IS NOT NULL")
    commands.find_each do |command|
      next if command.cancelled? || compatible_write_target?(command, appointment, previous)

      raise Scheduling::Error.new(
        code: 'MEDELEMENT_BOOKING_REQUIRES_VERIFICATION',
        message: 'Patient identity is locked while a provider write requires verification', status: :conflict
      )
    end
  end

  def compatible_write_target?(command, appointment, previous)
    return false unless binding_current?(command, appointment)
    unless frozen?(command.request_snapshot)
      return !marked?(appointment.custom_attributes) || completed_legacy_marker_adoption?(command, previous, current_snapshot(appointment))
    end

    current_snapshot(appointment) == command.request_snapshot[SNAPSHOT_KEY]
  end

  def completed_legacy_marker_adoption?(command, previous, current)
    return false unless command.succeeded?
    return false if previous['owned'] || previous['explicit_identifier']

    previous['fields'] == current['fields']
  end

  def binding_current?(command, appointment = command.appointment)
    Integrations::Medelement::AppointmentPatientBindingSnapshot.current?(command, appointment: appointment)
  end

  def validate_source_attributes!(appointment, attributes)
    keys = [EXPLICIT_IDENTIFIER_KEY, OWNED_IDENTITY_KEY]
    return unless keys.any? { |key| appointment.custom_attributes.to_h[key] == true && attributes[key] != true }

    raise Scheduling::Error.new(
      code: 'MEDELEMENT_PATIENT_IDENTITY_CONFLICT', message: 'The captured source no longer identifies the appointment patient', status: :conflict
    )
  end

  def normalize(key, value)
    return Scheduling::IinValidator.normalize(value) if key == 'client_identifier'
    return Integrations::Medelement::PhoneNumber.normalize(value) if key == 'client_phone'

    value.to_s.squish.downcase.presence
  end

  def contact_iin(contact)
    attributes = contact&.custom_attributes.to_h
    values = [attributes['medelement_iin'], attributes['iin'], contact&.identifier]
    value = values.find { |candidate| Scheduling::IinValidator.valid?(candidate) }
    Scheduling::IinValidator.normalize(value) if value
  end

  def contact_names(contact)
    attributes = contact&.custom_attributes.to_h
    return NAME_KEYS.index_with { |key| attributes["medelement_#{key}"] } if NAME_KEYS.any? { |key| attributes["medelement_#{key}"].present? }

    { 'first_name' => contact&.name, 'last_name' => contact&.last_name, 'middle_name' => contact&.middle_name }
  end

  def names_match?(identity, contact)
    names = contact_names(contact)
    return false if names['first_name'].blank? || names['last_name'].blank?

    NAME_KEYS.all? { |key| normalize("client_#{key}", identity[key.to_sym]) == normalize("client_#{key}", names[key]) }
  end
end
