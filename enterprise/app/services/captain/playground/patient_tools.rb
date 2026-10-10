module Captain::Playground::PatientTools
  PATIENT_FIELDS = %w[first_name last_name middle_name iin birth_date gender phone].freeze

  private

  def resolve_patient
    return caller unless @args['patient'].present?

    patient = @args['patient'].to_h.slice(*PATIENT_FIELDS)
    raise ArgumentError, 'Patient first and last names are required' if patient['first_name'].blank? || patient['last_name'].blank?

    patient['iin'] = normalized_iin(patient['iin']) if patient['iin'].present?
    if patient['birth_date'].present?
      raise ArgumentError, 'Patient birth date must use YYYY-MM-DD' unless patient['birth_date'].match?(/\A\d{4}-\d{2}-\d{2}\z/)

      Date.iso8601(patient['birth_date'])
    end
    existing_patient(patient) || create_patient(patient)
  end

  def normalized_iin(value)
    normalized = Scheduling::IinValidator.normalize(value)
    raise ArgumentError, 'Invalid IIN' unless Scheduling::IinValidator.valid?(normalized)

    normalized
  end

  def existing_patient(patient)
    return if patient['iin'].blank?

    candidates = @data['contacts'].select do |record|
      record['identifier'] == patient['iin'] && record.dig('custom_attributes', 'medelement_patient_card') == true
    end
    raise ArgumentError, 'Patient identity is ambiguous' if candidates.size > 1

    record = candidates.first
    return unless record

    validate_patient_identity!(patient, record)
    record
  end

  def validate_patient_identity!(patient, record)
    names = record['custom_attributes']
    %w[first_name last_name middle_name].each do |field|
      supplied = patient.fetch(field, names["medelement_#{field}"])
      unless supplied.to_s.squish.casecmp?(names["medelement_#{field}"].to_s.squish)
        raise ArgumentError, 'Patient name does not match the recorded IIN'
      end
    end
    recorded_birth_date = names['birth_date']
    return if patient['birth_date'].blank? || recorded_birth_date.blank? || patient['birth_date'] == recorded_birth_date

    raise ArgumentError, 'Patient birth date does not match the recorded card'
  end

  def create_patient(patient)
    fingerprint = Digest::SHA256.hexdigest(JSON.generate(patient.sort.to_h))
    requests = @data['patient_creation_requests'] ||= {}
    return record!('contacts', requests[fingerprint]) if requests.key?(fingerprint)

    phone = patient['phone'].presence || caller['phone_number']
    holder = @data['contacts'].find { |record| record['phone_number'].present? && record['phone_number'] == phone }
    attributes = patient_custom_attributes(patient, phone: phone, holder: holder)
    record = { 'id' => @scenario.next_id!, 'name' => %w[first_name last_name middle_name].filter_map { |field| patient[field].presence }.join(' '),
               'identifier' => patient['iin'], 'phone_number' => holder ? nil : phone,
               'custom_attributes' => attributes, 'additional_attributes' => {} }
    @data['contacts'] << record
    requests[fingerprint] = record['id']
    record
  end

  def patient_custom_attributes(patient, phone:, holder:)
    attributes = { 'medelement_patient_card' => true, 'birth_date' => patient['birth_date'], 'iin' => patient['iin'] }.compact
    %w[first_name last_name middle_name].each { |field| attributes["medelement_#{field}"] = patient[field] if patient[field].present? }
    return attributes unless holder

    attributes.merge('secondary_phones' => [phone], 'medelement_shared_phone_number' => phone,
                     'medelement_shared_phone_owner_contact_id' => holder['id'], 'medelement_shared_phone_via' => 'owner_primary',
                     'medelement_shared_phone_conversation_id' => @data['conversation']['id'])
  end

  def patient_phone(patient)
    patient['phone_number'].presence || Array(patient.dig('custom_attributes', 'secondary_phones')).first || caller['phone_number']
  end
end
