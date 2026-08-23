# rubocop:disable Metrics/ClassLength
class Integrations::Medelement::ProviderCommands::RequestSnapshotBuilder
  VERSION = 2
  PATIENT_PHONE_OPERATIONS = %w[create_patient update_patient create_reception move_reception].freeze
  SnapshotSchemaError = Integrations::Medelement::ProviderCommands::RequestSnapshotSchema::Error

  class << self
    def fingerprint(snapshot)
      Digest::SHA256.hexdigest(JSON.generate(canonicalize(snapshot)))
    end

    def valid_schema?(snapshot)
      Integrations::Medelement::ProviderCommands::RequestSnapshotSchema.valid?(snapshot)
    end

    def validate_schema!(snapshot)
      Integrations::Medelement::ProviderCommands::RequestSnapshotSchema.validate!(snapshot)
    end

    def service_codes(snapshot)
      Integrations::Medelement::ProviderCommands::RequestSnapshotSchema.service_codes(snapshot)
    end

    private

    def canonicalize(value)
      case value
      when Hash
        value.keys.sort.index_with { |key| canonicalize(value.fetch(key)) }
      when Array
        value.map { |item| canonicalize(item) }
      else
        value
      end
    end
  end

  # This boundary mirrors the command API payload; keyword arguments keep call sites explicit.
  # rubocop:disable Metrics/ParameterLists
  def initialize(
    account:, hook:, operation:, appointment: nil, contact: nil, actor: nil, company_cabinet_code: nil,
    desired_starts_at: nil, desired_ends_at: nil, desired_attributes: {}
  )
    @account = account
    @hook = hook
    @appointment = appointment
    @contact = contact || appointment&.contact
    @actor = actor
    @operation = operation.to_s
    @company_cabinet_code = company_cabinet_code.to_s.presence ||
                            appointment&.custom_attributes&.to_h&.dig('medelement_cabinet_code').to_s.presence
    @desired_starts_at = desired_starts_at
    @desired_ends_at = desired_ends_at
    @desired_attributes = desired_attributes.to_h.deep_stringify_keys
  end
  # rubocop:enable Metrics/ParameterLists

  # rubocop:disable Metrics/AbcSize
  def build
    {
      'version' => VERSION,
      'account_id' => account.id,
      'hook_id' => hook&.id,
      'organization_id' => configuration.organization_id,
      'appointment_id' => appointment&.id,
      'contact_id' => contact&.id,
      'requested_by_id' => actor&.id,
      'operation' => operation,
      'provider_patient_code' => patient_code,
      'patient_phone_numbers' => patient_phone_numbers.presence,
      'provider_reception_code' => reception_code,
      'company_cabinet_code' => company_cabinet_code,
      'desired_starts_at' => timestamp(desired_starts_at),
      'desired_ends_at' => timestamp(desired_ends_at),
      'patient' => patient_snapshot,
      'reception' => reception_snapshot,
      'confirmation' => confirmation_snapshot
    }.compact
  end
  # rubocop:enable Metrics/AbcSize

  private

  attr_reader :account, :hook, :appointment, :contact, :actor, :operation, :company_cabinet_code,
              :desired_starts_at, :desired_ends_at, :desired_attributes

  def patient_snapshot
    return unless patient_payload_required?

    phone_number = patient_phone_number
    phone_numbers = patient_phone_numbers
    payload = Integrations::Medelement::ProviderCommands::PatientPayloadBuilder.new(
      contact: contact,
      patient_code: operation == 'update_patient' ? patient_code : nil,
      phone_number: phone_number,
      identity: appointment_identity,
      organization_id: configuration.organization_id,
      desired_attributes: contact_desired_attributes
    ).build
    {
      'phone_number' => phone_number.to_s,
      'phone_numbers' => phone_numbers,
      'payload' => payload
    }
  end

  def patient_phone_number
    raw_phone = operation == 'create_reception' ? appointment_attribute('client_phone').presence : nil
    raw_phone ||= contact_desired_attributes.fetch('phone_number', contact&.phone_number)
    Integrations::Medelement::PhoneNumber.new(raw_phone).e164
  end

  def appointment_identity
    return {} if appointment.blank? || appointment_attribute('client_first_name').blank?

    {
      first_name: appointment_attribute('client_first_name'),
      last_name: appointment_attribute('client_last_name'),
      middle_name: appointment_attribute('client_middle_name')
    }.merge(appointment_demographic_identity)
  end

  def appointment_demographic_identity
    {
      iin: appointment_iin,
      birth_date: appointment_or_contact_identity(:client_birth_date, %w[medelement_birth_date birth_date]),
      gender: appointment_or_contact_identity(:client_gender, %w[medelement_gender gender])
    }
  end

  def appointment_iin
    contact_attributes = contact_snapshot_custom_attributes
    candidates = [
      appointment_attribute('client_identifier'),
      contact_attributes['medelement_iin'],
      contact_attributes['iin'],
      contact_desired_attributes.fetch('identifier', contact&.identifier)
    ]
    value = candidates.find { |candidate| Scheduling::IinValidator.valid?(candidate) }
    Scheduling::IinValidator.normalize(value) if value
  end

  def appointment_or_contact_identity(appointment_attribute, contact_attribute_keys, fallback = nil)
    self.appointment_attribute(appointment_attribute).presence ||
      contact_attribute_keys.filter_map { |key| contact_snapshot_custom_attributes[key].presence }.first ||
      fallback.presence
  end

  def patient_phone_numbers
    return [] unless operation.in?(PATIENT_PHONE_OPERATIONS)

    return Array(patient_phone_number) if contact_desired_attributes.key?('phone_number')

    contact_phones = frozen_contact_phones
    operation == 'create_reception' && appointment_attribute('client_phone').present? ? [patient_phone_number] : contact_phones
  end

  def patient_payload_required?
    operation == 'update_patient' || (operation.in?(%w[create_patient create_reception]) && patient_code.blank?)
  end

  def reception_snapshot
    return if appointment.blank?

    service_codes = nomenclature_codes
    {
      'time_zone' => configuration.time_zone,
      'specialist_code' => specialist_code,
      'source_starts_at' => timestamp(source_appointment_attribute('starts_at')),
      'source_ends_at' => timestamp(source_appointment_attribute('ends_at')),
      'destination_starts_at' => timestamp(destination_starts_at),
      'destination_ends_at' => timestamp(destination_ends_at),
      'description' => appointment_attribute('client_comment').to_s.presence,
      'nomenclature_code' => service_codes.first,
      'nomenclature_codes' => service_codes
    }.compact
  end

  def confirmation_snapshot
    return if appointment.blank?

    {
      'patient_name' => appointment_attribute('client_name'),
      'specialist_name' => desired_attributes.fetch(
        Integrations::Medelement::OutboundChangeService::SPECIALIST_NAME_KEY,
        appointment.resource.name
      ),
      'service_name' => desired_attributes.fetch(
        Integrations::Medelement::OutboundChangeService::SERVICE_NAME_KEY,
        appointment.service_name_snapshot.presence || appointment.service&.name
      ),
      'price' => appointment_attribute('service_amount'),
      'duration_min' => appointment_attribute('duration_min')
    }.compact
  end

  def destination_starts_at
    desired_starts_at || appointment_attribute('starts_at')
  end

  def destination_ends_at
    desired_ends_at || appointment_attribute('ends_at')
  end

  def specialist_code
    desired_attributes.fetch(
      Integrations::Medelement::OutboundChangeService::SPECIALIST_CODE_KEY,
      appointment.resource.custom_attributes.to_h['medelement_specialist_code']
    ).to_s
  end

  def nomenclature_codes
    frozen_codes = desired_attributes[Integrations::Medelement::OutboundChangeService::NOMENCLATURE_CODES_KEY]
    return Array(frozen_codes).filter_map { |code| code.to_s.presence }.uniq if frozen_codes

    service_ids = nomenclature_service_ids
    services_by_id = account.scheduling_services.where(id: service_ids).index_by(&:id)
    service_ids.filter_map do |service_id|
      services_by_id[service_id]&.custom_attributes&.dig('medelement_nomenclature_code').presence
    end.uniq
  end

  def nomenclature_service_ids
    service_ids = Array(appointment_snapshot_custom_attributes['service_ids']).filter_map do |value|
      Integer(value, exception: false)
    end
    service_ids.presence || [appointment.service_id].compact
  end

  def configuration
    @configuration ||= Integrations::Medelement::Configuration.new(hook: hook)
  end

  def patient_code
    contact_patient_code || appointment_patient_code
  end

  def contact_patient_code
    attributes = contact_desired_attributes.fetch('custom_attributes', contact&.custom_attributes).to_h
    attributes['medelement_patient_code'].presence
  end

  def appointment_patient_code
    appointment_snapshot_custom_attributes['medelement_patient_code'].presence
  end

  def reception_code
    return if appointment.blank?

    appointment_snapshot_custom_attributes['medelement_reception_code'].presence ||
      appointment_attribute('external_ref').to_s.delete_prefix('medelement:reception:').presence
  end

  def timestamp(value)
    value&.utc&.iso8601(6)
  end

  def appointment_attribute(key)
    desired_attributes.fetch(key.to_s) { appointment.public_send(key) }
  end

  def source_appointment_attribute(key)
    desired_attributes.fetch("medelement_source_#{key}") { appointment.public_send(key) }
  end

  def contact_desired_attributes
    return desired_attributes if operation.in?(%w[create_patient update_patient])
    return desired_attributes.fetch(Integrations::Medelement::OutboundChangeService::CONTACT_SNAPSHOT_KEY, {}) if appointment.present?

    {}
  end

  def appointment_snapshot_custom_attributes
    return {} if appointment.blank?

    desired_attributes.fetch('custom_attributes', appointment.custom_attributes).to_h
  end

  def contact_snapshot_custom_attributes
    contact_desired_attributes.fetch('custom_attributes', contact&.custom_attributes).to_h
  end

  def frozen_contact_phones
    values = [
      contact_desired_attributes.fetch('phone_number', contact&.phone_number),
      *Array(contact_snapshot_custom_attributes['secondary_phones'])
    ]

    values.flat_map do |value|
      Integrations::Medelement::PhoneNumber.extract(value).presence ||
        Array(Integrations::Medelement::PhoneNumber.normalize(value))
    end.uniq
  end
end
# rubocop:enable Metrics/ClassLength
