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
    desired_starts_at: nil, desired_ends_at: nil
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
  end
  # rubocop:enable Metrics/ParameterLists

  def build
    {
      'version' => VERSION,
      'account_id' => account.id,
      'hook_id' => hook&.id,
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

  private

  attr_reader :account, :hook, :appointment, :contact, :actor, :operation, :company_cabinet_code,
              :desired_starts_at, :desired_ends_at

  def patient_snapshot
    return unless patient_payload_required?

    phone_number = patient_phone_number
    phone_numbers = Integrations::Medelement::PhoneNumber.contact_phones(contact)
    payload = Integrations::Medelement::ProviderCommands::PatientPayloadBuilder.new(
      contact: contact,
      patient_code: operation == 'update_patient' ? patient_code : nil,
      phone_number: phone_number,
      identity: appointment_identity
    ).build
    {
      'phone_number' => phone_number.to_s,
      'phone_numbers' => phone_numbers,
      'payload' => payload
    }
  end

  def patient_phone_number
    contact&.phone_number
  end

  def appointment_identity
    return {} if appointment.blank? || appointment.client_first_name.blank?

    {
      first_name: appointment.client_first_name,
      last_name: appointment.client_last_name,
      middle_name: appointment.client_middle_name
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
    contact_attributes = contact&.custom_attributes.to_h
    candidates = [
      appointment.client_identifier,
      contact_attributes['medelement_iin'],
      contact_attributes['iin'],
      contact&.identifier
    ]
    value = candidates.find { |candidate| Scheduling::IinValidator.valid?(candidate) }
    Scheduling::IinValidator.normalize(value) if value
  end

  def appointment_or_contact_identity(appointment_attribute, contact_attribute_keys, fallback = nil)
    appointment.public_send(appointment_attribute).presence ||
      contact_attribute_keys.filter_map { |key| contact&.custom_attributes.to_h[key].presence }.first ||
      fallback.presence
  end

  def patient_phone_numbers
    return [] unless operation.in?(PATIENT_PHONE_OPERATIONS)

    @patient_phone_numbers ||= Integrations::Medelement::PhoneNumber.contact_phones(contact)
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
      'source_starts_at' => timestamp(appointment.starts_at),
      'source_ends_at' => timestamp(appointment.ends_at),
      'destination_starts_at' => timestamp(destination_starts_at),
      'destination_ends_at' => timestamp(destination_ends_at),
      'description' => appointment.client_comment.to_s.presence,
      'nomenclature_code' => service_codes.first,
      'nomenclature_codes' => service_codes
    }.compact
  end

  def confirmation_snapshot
    return if appointment.blank?

    {
      'patient_name' => appointment.client_name,
      'specialist_name' => appointment.resource.name,
      'service_name' => appointment.service_name_snapshot.presence || appointment.service&.name,
      'price' => appointment.service_amount,
      'duration_min' => appointment.duration_min
    }.compact
  end

  def destination_starts_at
    operation == 'move_reception' ? desired_starts_at : appointment.starts_at
  end

  def destination_ends_at
    operation == 'move_reception' ? desired_ends_at : appointment.ends_at
  end

  def specialist_code
    appointment.resource.custom_attributes.to_h['medelement_specialist_code'].to_s
  end

  def nomenclature_codes
    service_ids = Array(appointment.custom_attributes.to_h['service_ids']).filter_map do |value|
      Integer(value, exception: false)
    end
    service_ids = [appointment.service_id].compact if service_ids.blank?
    services_by_id = account.scheduling_services.where(id: service_ids).index_by(&:id)

    service_ids.filter_map do |service_id|
      services_by_id[service_id]&.custom_attributes&.dig('medelement_nomenclature_code').presence
    end.uniq
  end

  def configuration
    @configuration ||= Integrations::Medelement::Configuration.new(hook: hook)
  end

  def patient_code
    contact_patient_code || appointment_patient_code
  end

  def contact_patient_code = contact&.custom_attributes&.dig('medelement_patient_code').presence

  def appointment_patient_code
    appointment&.custom_attributes&.to_h&.dig('medelement_patient_code').presence
  end

  def reception_code
    return if appointment.blank?

    appointment.custom_attributes.to_h['medelement_reception_code'].presence ||
      appointment.external_ref.to_s.delete_prefix('medelement:reception:').presence
  end

  def timestamp(value)
    value&.utc&.iso8601(6)
  end
end
