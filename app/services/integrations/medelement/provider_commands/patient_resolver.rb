# rubocop:disable Metrics/ClassLength
class Integrations::Medelement::ProviderCommands::PatientResolver
  WRITE_RESPONSE_KEYS = {
    'profile_code' => 'PROFILE_CODE',
    'patient_code' => 'PATIENT_CODE',
    'name' => 'NAME',
    'lastname' => 'LASTNAME',
    'middlename' => 'MIDDLENAME',
    'birthday' => 'BIRTHDAY',
    'gender' => 'GENDER',
    'iin' => 'IIN',
    'patient_email' => 'PATIENT_EMAIL',
    'patient_phone_2' => 'PATIENT_PHONE_2'
  }.freeze

  def initialize(command:, client:, before_create: nil, organization_id: nil)
    @command = command
    @client = client
    @before_create = before_create
    @organization_id = organization_id
  end

  def resolve!(allow_create:)
    return resolve_linked_patient! if snapshot_patient_code.present?

    return with_identity_lock { resolve_unlinked!(allow_create: allow_create) } if strong_identifier_lookup?

    resolve_unlinked!(allow_create: allow_create)
  end

  def resolve_unlinked!(allow_create:)
    raise deterministic_error('patient_identity_conflict') if local_identity_owner.present?

    matches = lookup_candidates
    resolved = resolve_candidate(matches)
    return resolved if resolved

    raise deterministic_error('patient_not_found') unless allow_create
    raise creation_required unless patient_creation_confirmed?

    create_patient!
  end
  private :resolve_unlinked!

  def resolve_candidate(matches)
    selected = selected_candidate(matches)
    return link_patient!(patient_code(selected), patient: selected, verify_phone: strong_identifier_lookup?) if selected
    return link_patient!(patient_code(matches.first), patient: matches.first, verify_phone: true) if strong_identifier_lookup? && matches.one?

    raise selection_required(matches.size) if matches.any?
  end
  private :resolve_candidate

  def candidate_options
    lookup_candidates.map do |patient|
      {
        token: candidate_token(patient),
        name: [patient['LASTNAME'], patient['NAME']].compact_blank.join(' '),
        middlename: patient['MIDDLENAME'].to_s.presence,
        birthday: patient['BIRTHDAY'].to_s.presence,
        iin_masked: masked_value(patient['IIN']),
        phone_masked: Integrations::Medelement::PhoneNumber.patient_phones(patient).filter_map do |phone|
          masked_value(phone)
        end.uniq.join(', ').presence
      }.compact
    end
  end

  def resolve_existing
    return snapshot_patient_code if snapshot_patient_code.present?

    matches = lookup_candidates
    patient_code(matches.first) if matches.one?
  end

  private

  attr_reader :command, :client, :before_create, :organization_id

  def resolve_linked_patient!
    patient = patient_by_code(snapshot_patient_code)
    raise deterministic_error('patient_not_found') if patient.blank?

    Integrations::Medelement::ProviderScope.validate_patient!(
      patient,
      organization_id: organization_id,
      expected_patient_code: snapshot_patient_code,
      expected_iin: desired_iin,
      expected_phone_numbers: snapshot_phone_numbers
    )
    validate_patient_ref!(snapshot_patient_code)
    command.update!(provider_patient_code: snapshot_patient_code.to_s)
    record_phone_warning!(patient)
    snapshot_patient_code.to_s
  end

  def lookup_candidates
    desired_iin = patient_snapshot.fetch('payload')['iin'].presence
    if desired_iin
      matches = Array(client.search_patients_by_iin(iin: desired_iin)).select do |patient|
        normalized_iin(patient['IIN']) == normalized_iin(desired_iin)
      end
      return validated_candidates(unique_candidates(matches))
    end

    candidates = snapshot_phone_numbers.flat_map do |phone_number|
      client.search_patients_by_phone(phone_number: phone_number)
    end
    validated_candidates(unique_candidates(identity_matches(candidates)))
  end

  def unique_candidates(candidates)
    Array(candidates).index_by { |patient| patient_code(patient).to_s }.except('').values
  end

  def validated_candidates(candidates)
    candidates.each do |patient|
      Integrations::Medelement::ProviderScope.validate_patient!(
        patient,
        organization_id: organization_id,
        expected_iin: desired_iin,
        expected_phone_numbers: snapshot_phone_numbers
      )
    end
  end

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

    matches = lookup_candidates
    collision_result = resolve_create_collision(matches)
    return collision_result if collision_result

    validate_create_payload!
    Integrations::Medelement::ProviderScope.validate_write!(
      patient_snapshot.fetch('payload'),
      organization_id: organization_id
    )

    before_create.call
    response = client.create_patient(params: patient_snapshot.fetch('payload'))
    code = patient_code(response)
    raise reconciliation_error('patient_create_missing_ref') if code.blank?

    patient = created_patient_response(response, code) || created_patient_readback(code)
    link_patient!(code, patient: patient, verify_phone: true)
  end

  def created_patient_response(response, code)
    normalized = normalize_write_response(response)
    desired = patient_snapshot.fetch('payload')
    return unless patient_code(normalized).to_s == code.to_s
    return unless write_response_fields_match?(normalized, desired)
    return unless snapshot_phone_numbers.any? { |phone| Integrations::Medelement::PhoneNumber.new(phone).matches_patient?(normalized) }

    normalized
  end

  def normalize_write_response(response)
    response.to_h.transform_keys { |key| WRITE_RESPONSE_KEYS.fetch(key.to_s, key.to_s) }
  end

  def write_response_fields_match?(patient, desired)
    {
      'name' => 'NAME', 'lastname' => 'LASTNAME', 'middlename' => 'MIDDLENAME',
      'birthday' => 'BIRTHDAY', 'gender' => 'GENDER', 'iin' => 'IIN'
    }.all? do |local_key, remote_key|
      desired[local_key].blank? || desired[local_key].to_s == patient[remote_key].to_s
    end
  end

  def resolve_create_collision(matches)
    return if matches.empty?
    return link_patient!(patient_code(matches.first), patient: matches.first, verify_phone: true) if strong_identifier_lookup? && matches.one?

    raise selection_required(matches.size)
  end

  def with_identity_lock(&)
    Integrations::Medelement::ProviderCommands::PatientIdentityLock.new(
      account_id: command.account_id,
      iin: desired_iin
    ).synchronize(&)
  end

  def local_identity_owner
    return if desired_iin.blank?

    command.account.contacts.where.not(id: command.contact_id)
           .where(
             "identifier = :iin OR custom_attributes ->> 'iin' = :iin OR custom_attributes ->> 'medelement_iin' = :iin",
             iin: desired_iin
           )
           .where("COALESCE(custom_attributes ->> 'medelement_patient_code', '') <> ''")
           .first
  end

  def created_patient_readback(code)
    patient = patient_by_code(code)
    return patient if patient.present?

    patient = created_patient_indexed_readback(code)
    return patient if patient.present?

    raise reconciliation_error('patient_create_readback_missing')
  rescue Integrations::Medelement::Client::ApiError
    patient = created_patient_indexed_readback(code)
    return patient if patient.present?

    raise reconciliation_error('patient_create_readback_failed')
  end

  def created_patient_indexed_readback(code)
    lookup_candidates.find { |patient| patient_code(patient).to_s == code.to_s }
  rescue Integrations::Medelement::Client::ApiError
    nil
  end

  def patient_by_code(code)
    client.get_patient(patient_code: code)
  rescue Integrations::Medelement::Client::ApiError => e
    patient = Array(client.search_patients_by_codes(patient_codes: [code])).find do |candidate|
      patient_code(candidate).to_s == code.to_s
    end
    return patient if patient.present?

    raise e
  end

  def link_patient!(code, patient: nil, verify_phone: false)
    raise reconciliation_error('patient_ref_missing') if code.blank?

    if patient
      Integrations::Medelement::ProviderScope.validate_patient!(
        patient,
        organization_id: organization_id,
        expected_patient_code: code,
        expected_iin: desired_iin,
        expected_phone_numbers: snapshot_phone_numbers
      )
    end
    validate_patient_ref!(code)
    update_contact_patient_ref!(code)
    command.update!(provider_patient_code: code.to_s)
    record_phone_warning!(patient) if patient && verify_phone
    sync_contact!(patient) if patient
    code.to_s
  end

  def validate_create_payload!
    missing = %w[name lastname middlename gender iin].select { |key| patient_snapshot.fetch('payload')[key].blank? }
    return if missing.empty?

    raise creation_required(missing_fields: missing)
  end

  def selection_required(count)
    Integrations::Medelement::ProviderCommands::PatientActionRequired.new(
      status: 'awaiting_patient_selection',
      code: 'patient_selection_required',
      metadata: { 'candidate_count' => count }
    )
  end

  def creation_required(missing_fields: required_create_fields)
    Integrations::Medelement::ProviderCommands::PatientActionRequired.new(
      status: 'awaiting_patient_creation',
      code: missing_fields.empty? ? 'patient_creation_confirmation_required' : 'patient_identity_incomplete',
      metadata: {
        'can_confirm' => missing_fields.empty?,
        'missing_fields' => missing_fields
      }
    )
  end

  def required_create_fields
    %w[name lastname middlename gender iin].select { |key| patient_snapshot.fetch('payload')[key].blank? }
  end

  def patient_creation_confirmed?
    return true if command.execution_state.to_h['patient_creation_confirmed'] == true

    confirmation = command.confirmation_request
    confirmation&.confirmed? && confirmation.resolution_source == 'system' &&
      confirmation.resolution_metadata.to_h['medelement_auto_sync'] == true
  end

  def selected_candidate(candidates)
    selected_token = command.execution_state.to_h['selected_patient_token'].to_s
    return if selected_token.blank?

    candidates.find { |patient| secure_token_match?(candidate_token(patient), selected_token) }
  end

  def strong_identifier_lookup?
    desired_iin.present?
  end

  def desired_iin
    @desired_iin ||= normalized_iin(command.request_snapshot['patient'].to_h['payload'].to_h['iin'])
  end

  def snapshot_phone_numbers
    stored_patient = command.request_snapshot['patient'].to_h
    values = command.request_snapshot['patient_phone_numbers'].presence ||
             stored_patient['phone_numbers'].presence ||
             Array(stored_patient['phone_number'].presence || command.contact&.phone_number)
    values.filter_map { |value| Integrations::Medelement::PhoneNumber.normalize(value) }.uniq
  end

  def candidate_token(patient)
    code = patient_code(patient).to_s
    key = Rails.application.key_generator.generate_key('medelement-patient-candidate', 32)
    OpenSSL::HMAC.hexdigest('SHA256', key, "#{command.account_id}:#{command.id}:#{code}")
  end

  def secure_token_match?(first, second)
    first.bytesize == second.bytesize && ActiveSupport::SecurityUtils.secure_compare(first, second)
  end

  def masked_value(value)
    digits = value.to_s.gsub(/\D/, '')
    return if digits.blank?

    "••••#{digits.last(4)}"
  end

  def validate_patient_ref!(code)
    linked_contact = command.account.contacts.find_by("custom_attributes ->> 'medelement_patient_code' = ?", code.to_s)
    return if linked_contact.blank? || linked_contact.id == command.contact_id

    raise reconciliation_error('patient_ref_conflict')
  end

  def update_contact_patient_ref!(code)
    command.contact.skip_runtime_events = true
    attributes = command.contact.custom_attributes.to_h.merge(
      'medelement_patient_code' => code.to_s,
      'medelement_patient_match_status' => 'matched',
      'medelement_last_synced_at' => Time.current.iso8601
    )
    attributes['iin'] = desired_iin if desired_iin.present?
    command.contact.update!(
      custom_attributes: attributes
    )
  end

  def record_phone_warning!(patient)
    phone_numbers = snapshot_phone_numbers
    raise deterministic_error('patient_phone_missing') if phone_numbers.empty?

    provider_phones = Integrations::Medelement::PhoneNumber.patient_phones(patient)
    return if phone_numbers.intersect?(provider_phones)

    warnings = Array(command.execution_state['warnings']).reject { |warning| warning['code'] == 'patient_phone_mismatch' }
    warnings << {
      'code' => 'patient_phone_mismatch',
      'provider_phone_masked' => masked_value(provider_phones.first)
    }.compact
    command.update!(
      execution_state: command.execution_state.except('patient_action').merge('warnings' => warnings)
    )
  end

  def sync_contact!(patient)
    Integrations::Medelement::ContactResolverService.new(
      account: command.account,
      client: client,
      organization_id: organization_id
    ).sync_patient_payload!(
      patient,
      preferred_contact: command.contact
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
      message: 'Medelement patient identity cannot be resolved automatically'
    )
  end
end
# rubocop:enable Metrics/ClassLength
