class Integrations::Medelement::PatientReadModelGuard
  def initialize(client:, conflict_tracker: nil, organization_id: nil)
    @client = client
    @conflict_tracker = conflict_tracker
    @organization_id = organization_id
  end

  def conflict?(patient_code:, direct_patient:, contact:)
    indexed_patient = indexed_patient(patient_code)
    return record_conflict(patient_code, contact, 'patient_read_model_unavailable') if indexed_patient.blank?

    Integrations::Medelement::ProviderScope.validate!(indexed_patient, organization_id: organization_id)
    return record_conflict(patient_code, contact, 'patient_read_model_unavailable') unless comparable_identity?(direct_patient, indexed_patient)
    return false unless identity_conflict?(direct_patient, indexed_patient)

    record_conflict(patient_code, contact, 'patient_read_model_conflict')
  rescue Integrations::Medelement::Client::ApiError
    record_conflict(patient_code, contact, 'patient_read_model_unavailable')
  end

  private

  attr_reader :client, :conflict_tracker, :organization_id

  def indexed_patient(patient_code)
    Array(client.search_patients_by_codes(patient_codes: [patient_code])).find do |patient|
      provider_patient_code(patient) == patient_code.to_s
    end
  end

  def provider_identity(patient)
    {
      first_name: normalized_text(patient_first_name(patient)),
      last_name: normalized_text(patient['LASTNAME']),
      middle_name: normalized_text(patient['MIDDLENAME']),
      iin: normalized_iin(patient['IIN'])
    }
  end

  def identity_conflict?(direct_patient, indexed_patient)
    direct_identity = provider_identity(direct_patient)
    indexed_identity = provider_identity(indexed_patient)

    direct_identity.any? do |field, value|
      value.present? && indexed_identity[field].present? && value != indexed_identity[field]
    end
  end

  def comparable_identity?(direct_patient, indexed_patient)
    direct_identity = provider_identity(direct_patient)
    indexed_identity = provider_identity(indexed_patient)

    direct_identity.all? do |field, value|
      value.present? == indexed_identity[field].present?
    end
  end

  def patient_first_name(patient)
    explicit_name = patient['NAME'].presence || patient['FIRSTNAME'].presence
    return explicit_name if explicit_name

    parts = patient['FULLNAME'].to_s.split
    parts.shift if patient['LASTNAME'].present? && parts.first == patient['LASTNAME'].to_s
    parts.pop if patient['MIDDLENAME'].present? && parts.last == patient['MIDDLENAME'].to_s
    parts.join(' ').presence
  end

  def provider_patient_code(patient)
    (patient['PROFILE_CODE'].presence || patient['PATIENT_CODE'].presence).to_s
  end

  def normalized_text(value)
    value.to_s.squish.mb_chars.downcase.to_s.presence
  end

  def normalized_iin(value)
    value.to_s.gsub(/\D/, '').presence
  end

  def record_conflict(patient_code, contact, conflict_type)
    conflict_tracker&.record!(
      phase: 'contacts',
      entity_type: 'contact',
      conflict_type: conflict_type,
      entity_key: patient_code,
      severity: 'error',
      details: {
        reason: conflict_reason(conflict_type),
        contact_id: contact&.id
      }.compact
    )
    true
  end

  def conflict_reason(conflict_type)
    return 'Provider patient read models disagree' if conflict_type == 'patient_read_model_conflict'

    'Provider indexed patient read is unavailable'
  end
end
