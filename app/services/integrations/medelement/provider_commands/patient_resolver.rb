class Integrations::Medelement::ProviderCommands::PatientResolver
  def initialize(command:, client:, before_create: nil)
    @command = command
    @client = client
    @before_create = before_create
  end

  def resolve!(allow_create:)
    return snapshot_patient_code if snapshot_patient_code.present?

    matches = identity_matches(client.search_patients_by_phone(phone_number: patient_snapshot.fetch('phone_number')))
    return link_patient!(patient_code(matches.first)) if matches.one?
    raise deterministic_error('patient_match_ambiguous') if matches.many?
    raise deterministic_error('patient_not_found') unless allow_create

    create_patient!
  end

  def resolve_existing
    return snapshot_patient_code if snapshot_patient_code.present?

    matches = identity_matches(client.search_patients_by_phone(phone_number: patient_snapshot.fetch('phone_number')))
    patient_code(matches.first) if matches.one?
  end

  private

  attr_reader :command, :client, :before_create

  def identity_matches(candidates)
    Array(candidates).select { |patient| patient_identity_matches?(patient) }
  end

  def patient_identity_matches?(patient)
    desired = patient_snapshot.fetch('payload')
    return normalized_iin(patient['IIN']) == normalized_iin(desired['iin']) if desired['iin'].present?

    names_match?(patient, desired) && birthday_matches?(patient, desired)
  end

  def names_match?(patient, desired)
    normalized_text(patient['NAME']) == normalized_text(desired['name']) &&
      normalized_text(patient['LASTNAME']) == normalized_text(desired['lastname']) &&
      middlename_matches?(patient, desired)
  end

  def middlename_matches?(patient, desired)
    desired['middlename'].blank? || normalized_text(patient['MIDDLENAME']) == normalized_text(desired['middlename'])
  end

  def birthday_matches?(patient, desired)
    desired['birthday'].blank? || patient['BIRTHDAY'].to_s == desired['birthday'].to_s
  end

  def normalized_iin(value)
    value.to_s.gsub(/\D/, '').presence
  end

  def normalized_text(value)
    value.to_s.squish.mb_chars.downcase.to_s
  end

  def create_patient!
    raise ArgumentError, 'before_create callback is required for patient writes' unless before_create

    before_create.call
    response = client.create_patient(params: patient_snapshot.fetch('payload'))
    code = patient_code(response)
    raise reconciliation_error('patient_create_missing_ref') if code.blank?

    link_patient!(code)
  end

  def link_patient!(code)
    raise reconciliation_error('patient_ref_missing') if code.blank?

    validate_patient_ref!(code)
    update_contact_patient_ref!(code) unless appointment_scoped?
    command.update!(provider_patient_code: code.to_s)
    code.to_s
  end

  def validate_patient_ref!(code)
    linked_contact = command.account.contacts.find_by("custom_attributes ->> 'medelement_patient_code' = ?", code.to_s)
    return if linked_contact.blank? || linked_contact.id == command.contact_id

    raise reconciliation_error('patient_ref_conflict')
  end

  def update_contact_patient_ref!(code)
    command.contact.skip_runtime_events = true
    command.contact.update!(
      custom_attributes: command.contact.custom_attributes.to_h.merge(
        'medelement_patient_code' => code.to_s,
        'medelement_patient_match_status' => 'matched',
        'medelement_last_synced_at' => Time.current.iso8601
      )
    )
  end

  def patient_code(payload)
    return if payload.blank?

    payload['profile_code'].presence || payload['PROFILE_CODE'].presence || payload['PATIENT_CODE'].presence
  end

  def patient_snapshot
    @patient_snapshot ||= command.request_snapshot.fetch('patient')
  end

  def snapshot_patient_code
    command.request_snapshot['provider_patient_code'].presence
  end

  def appointment_scoped?
    command.operation == 'create_reception'
  end

  def reconciliation_error(code)
    Integrations::Medelement::ProviderCommands::ExecutionError.new(
      code: code,
      message: 'Medelement patient identity requires reconciliation',
      reconciliation: true
    )
  end

  def deterministic_error(code)
    Integrations::Medelement::ProviderCommands::ExecutionError.new(
      code: code,
      message: 'Medelement patient was not found'
    )
  end
end
