class Integrations::Medelement::ProviderCommands::RequestSnapshotBuilder
  VERSION = 1

  class << self
    def fingerprint(snapshot)
      Digest::SHA256.hexdigest(JSON.generate(canonicalize(snapshot)))
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
    @company_cabinet_code = company_cabinet_code.to_s.presence
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

    {
      'phone_number' => phone_number.to_s,
      'payload' => Integrations::Medelement::ProviderCommands::PatientPayloadBuilder.new(
        contact: contact,
        patient_code: operation == 'update_patient' ? patient_code : nil,
        phone_number: phone_number,
        identity: patient_identity
      ).build
    }
  end

  def patient_identity
    return unless operation == 'create_reception'

    {
      full_name: appointment.client_name,
      iin: appointment_iin,
      birth_date: appointment.client_birth_date,
      gender: appointment.client_gender
    }.compact
  end

  def appointment_iin
    value = appointment.client_identifier
    Scheduling::IinValidator.normalize(value) if Scheduling::IinValidator.valid?(value)
  end

  def patient_phone_number
    return contact.phone_number unless operation == 'create_reception'

    appointment.client_phone.presence || contact.phone_number
  end

  def patient_payload_required?
    operation == 'update_patient' || (operation.in?(%w[create_patient create_reception]) && patient_code.blank?)
  end

  def reception_snapshot
    return if appointment.blank?

    {
      'time_zone' => configuration.time_zone,
      'specialist_code' => specialist_code,
      'source_starts_at' => timestamp(appointment.starts_at),
      'source_ends_at' => timestamp(appointment.ends_at),
      'destination_starts_at' => timestamp(destination_starts_at),
      'destination_ends_at' => timestamp(destination_ends_at),
      'description' => appointment.client_comment.to_s.presence,
      'nomenclature_code' => nomenclature_code
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

  def nomenclature_code
    appointment.service&.custom_attributes&.dig('medelement_nomenclature_code').presence
  end

  def configuration
    @configuration ||= Integrations::Medelement::Configuration.new(hook: hook)
  end

  def patient_code
    return appointment_patient_code if operation == 'create_reception'

    appointment_patient_code || contact&.custom_attributes&.dig('medelement_patient_code').presence
  end

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
