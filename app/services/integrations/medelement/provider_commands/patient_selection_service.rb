# rubocop:disable Metrics/ClassLength
class Integrations::Medelement::ProviderCommands::PatientSelectionService
  POLICY = Integrations::Medelement::AppointmentPatientIdentity

  def initialize(command:, actor:, patient:, expected_fingerprint:)
    @command = command
    @actor = actor
    @patient = patient.to_h
    @expected_fingerprint = expected_fingerprint
  end

  # PatientActionsService owns the command lock. No provider request is made while holding
  # these locks. Selection changes only the patient part of the already confirmed intent.
  def perform
    return unless command.create_reception? && command.appointment

    appointment.with_lock do
      Contacts::PhoneIdentityLock.acquire!(account_id: command.account_id)
      validate_original_intent!
      original = command.request_snapshot.deep_dup
      previous_confirmation = command.confirmation_request
      bind_selected_patient!
      refresh_receipt!(original, previous_confirmation)
    end
  end

  private

  attr_reader :command, :actor, :patient, :expected_fingerprint

  def appointment = command.appointment

  def patient_code
    Integrations::Medelement::ProviderCommands::PatientResolver.patient_code(patient).to_s
  end

  def patient_iin
    value = patient['IIN'].presence || patient['iin']
    Scheduling::IinValidator.normalize(value) if Scheduling::IinValidator.valid?(value)
  end

  def validate_original_intent!
    conflict!('Patient selection requires an account employee') unless actor.is_a?(User) && command.account.users.exists?(id: actor.id)
    current_fingerprint = command.execution_state.to_h['request_fingerprint']
    conflict!('The confirmed booking changed during patient selection') unless current_fingerprint == expected_fingerprint
    confirmation = command.confirmation_request
    valid = command.request_snapshot_valid? && confirmation&.confirmed? &&
            command.confirmation_matches_request_snapshot?(confirmation) &&
            confirmation.requested_by_id == command.requested_by_id && confirmation.contact_id == command.contact_id &&
            confirmation.subject == appointment
    conflict!('The original booking confirmation is no longer valid') unless valid
    conflict!('The appointment no longer matches the confirmed booking') unless
      Integrations::Medelement::ProviderCommands::ReceptionDiscoveryGuard.new(command: command).current_booking?
    status = Integrations::Medelement::AppointmentProviderStatus
    if appointment.custom_attributes.to_h[status::COMMAND_ID_KEY].present? && !status.bound_to_command?(appointment, command)
      conflict!('Another command now owns this appointment')
    end
    validate_prewrite!
    validate_original_patient!
    validate_provider_scope!
    validate_placeholder!
  end

  def validate_prewrite!
    commands = Integrations::Medelement::ProviderCommand.where(account_id: command.account_id, appointment_id: appointment.id)
    conflict!('A provider write must be verified before choosing another patient') if commands.any?(&:provider_write_started?)
    conflict!('Another appointment command is still active') if commands.unfinished.where.not(id: command.id).exists?
    linked = appointment.external_ref.present? || appointment.custom_attributes.to_h['medelement_reception_code'].present?
    conflict!('The appointment already has a provider reception') if linked
    captured = command.request_snapshot['provider_patient_code'].presence || command.provider_patient_code.presence
    conflict!('The confirmed booking already identifies another provider patient') if captured.present? && captured.to_s != patient_code
  end

  def validate_original_patient!
    return if POLICY.frozen?(command.request_snapshot)

    expected_name = command.request_snapshot.dig('confirmation', 'patient_name')
    conflict!('The authored patient changed after booking confirmation') if expected_name.present? && expected_name != appointment.client_name
    payload = command.request_snapshot.dig('patient', 'payload').to_h
    POLICY::NAME_KEYS.each do |key|
      field = "client_#{key}"
      source = { 'first_name' => 'name', 'last_name' => 'lastname', 'middle_name' => 'middlename' }.fetch(key)
      validate_patient_value!(field, appointment.public_send(field), payload[source])
    end
    validate_patient_value!('client_identifier', appointment.client_identifier, payload['iin'])
    validate_patient_value!('client_birth_date', appointment.client_birth_date&.iso8601, payload['birthday'])
    if payload['gender'].present?
      validate_patient_value!('client_gender', appointment.client_gender, payload['gender'])
      validate_patient_value!('client_gender', patient['GENDER'], payload['gender'])
    end
    phone = Integrations::Medelement::PhoneNumber.normalize(appointment.client_phone)
    expected_phones = command.request_snapshot['patient_phone_numbers'].presence || command.request_snapshot.dig('patient', 'phone_numbers')
    if phone.present? && expected_phones.present? && Array(expected_phones).exclude?(phone)
      conflict!('The authored patient phone changed after booking confirmation')
    end
  end

  def validate_provider_scope!
    hook = command.hook.reload
    configuration = Integrations::Medelement::Configuration.new(hook: hook)
    valid = hook.account_id == command.account_id && hook.enabled? && hook.feature_allowed? && configuration.write_enabled? &&
            command.request_snapshot['organization_id'].to_s == configuration.organization_id.to_s
    conflict!('The provider configuration changed after confirmation') unless valid
    conflict!('The selected patient reference is missing') if patient_code.blank?
    Integrations::Medelement::ProviderScope.validate_patient!(
      patient, organization_id: configuration.organization_id, expected_patient_code: patient_code,
      expected_iin: appointment.client_identifier.presence, expected_phone_numbers: command.request_snapshot['patient_phone_numbers']
    )
  end

  def validate_placeholder!
    card = appointment.patient_contact
    return unless card

    code = card.custom_attributes.to_h['medelement_patient_code'].to_s.presence
    recorded = appointment.custom_attributes.to_h['medelement_patient_code'].to_s.presence
    conflict!('The appointment already identifies another provider patient') if [code, recorded].compact.any? { |value| value != patient_code }
    return if code == patient_code

    replaceable = card.custom_attributes.to_h[Contacts::SharedPhone::CARD_KEY] == true &&
                  !card.patient_scheduling_appointments.where.not(id: appointment.id).exists?
    conflict!('The appointment patient card is not a replaceable draft') unless replaceable
    validate_iin!(POLICY.contact_iin(card))
  end

  def bind_selected_patient!
    card = command.account.contacts.lock.find_by("custom_attributes ->> 'medelement_patient_code' = ?", patient_code)
    selected_owner = card&.id == command.contact_id
    validate_selected_owner!(card) if selected_owner
    validate_iin!(POLICY.contact_iin(card)) if card
    validate_iin!(appointment.client_identifier)
    apply_missing_patient_fields!
    appointment.client_identifier = patient_iin if appointment.client_identifier.blank? && patient_iin.present?
    attributes = appointment.custom_attributes.to_h.merge('medelement_patient_code' => patient_code, POLICY::OWNED_IDENTITY_KEY => true)
    attributes[POLICY::EXPLICIT_IDENTIFIER_KEY] = true if appointment.client_identifier.present?
    appointment.custom_attributes = attributes
    binding = Integrations::Medelement::PatientContactBinding.new(appointment: appointment)
    if card
      binding.prepare_selected!(contact: card, allow_communication_contact: selected_owner)
    else
      binding.prepare!(patient_code: patient_code, allow_rebind: true)
    end
    conflict!('The selected patient card could not be recorded') unless appointment.patient_contact_id
    Integrations::Medelement::AppointmentPatientIdentity.ensure_write_target_unchanged!(appointment)
    appointment.mark_medelement_provider_reconciled!
    appointment.save!
  end

  def validate_iin!(value)
    known = Scheduling::IinValidator.normalize(value).presence
    return if known.blank?
    return if patient_iin.present? && known == patient_iin

    conflict!('The selected provider patient does not match the recorded IIN')
  end

  # An existing, strongly verified patient may also be the communication owner. This
  # admission never transfers its provider profile or changes its other appointments.
  def validate_selected_owner!(owner)
    attributes = owner.custom_attributes.to_h
    verified = Scheduling::IinValidator.valid?(attributes['medelement_iin']) &&
               attributes['medelement_patient_code'].to_s == patient_code && patient_iin.present?
    conflict!('The chat owner provider identity is not strongly verified') unless verified
    validate_iin!(attributes['medelement_iin'])
    [owner.identifier, attributes['iin']].each { |value| validate_iin!(value) if Scheduling::IinValidator.valid?(value) }
    names = POLICY.contact_names(owner)
    conflict!('The recorded owner patient name cannot be verified') if names.values_at('first_name', 'last_name').any?(&:blank?)
    validate_names!(names)
    validate_patient_value!('client_birth_date', attributes['medelement_birth_date'], patient['BIRTHDAY'])
  end

  def apply_missing_patient_fields!
    names = { 'first_name' => patient['NAME'], 'last_name' => patient['LASTNAME'], 'middle_name' => patient['MIDDLENAME'] }
    authored = POLICY::NAME_KEYS.index_with { |key| appointment.public_send("client_#{key}") }
    validate_names!(authored)
    POLICY::NAME_KEYS.each do |key|
      field = "client_#{key}"
      appointment.public_send("#{field}=", names[key]) if appointment.public_send(field).blank? && names[key].present?
    end
    validate_patient_value!('client_birth_date', appointment.client_birth_date&.iso8601, patient['BIRTHDAY'])
    validate_patient_value!('client_gender', appointment.client_gender, patient['GENDER'])
    if appointment.client_birth_date.blank? && patient['BIRTHDAY'].present?
      appointment.client_birth_date = Date.parse(patient['BIRTHDAY'].to_s)
    end
    appointment.client_gender = patient['GENDER'] if appointment.client_gender.blank? && patient['GENDER'].present?
    appointment.client_name = POLICY::NAME_KEYS.filter_map { |key| appointment.public_send("client_#{key}").presence }.join(' ')
  rescue Date::Error
    conflict!('The selected patient birth date cannot be verified')
  end

  def validate_names!(names)
    remote = { 'first_name' => patient['NAME'], 'last_name' => patient['LASTNAME'], 'middle_name' => patient['MIDDLENAME'] }
    names.each { |key, value| validate_patient_value!("client_#{key}", value, remote[key]) }
  end

  def validate_patient_value!(field, recorded, remote)
    return if recorded.blank? || remote.blank?
    return if normalized_patient_value(field, recorded) == normalized_patient_value(field, remote)

    conflict!('The selected provider patient contradicts the recorded patient details')
  end

  def normalized_patient_value(field, value)
    return Date.parse(value.to_s).iso8601 if field == 'client_birth_date'
    if field == 'client_gender'
      normalized = value.to_s.downcase
      return { 'male' => '2', 'm' => '2', 'female' => '1', 'f' => '1' }.fetch(normalized, normalized)
    end
    POLICY.normalize(field, value)
  rescue Date::Error
    conflict!('The selected patient birth date cannot be verified')
  end

  def refreshed_snapshot(original)
    original.deep_dup.merge(
      POLICY::BINDING_KEY => appointment.patient_contact_id,
      POLICY::SNAPSHOT_KEY => POLICY.current_snapshot(appointment),
      'provider_patient_code' => patient_code,
      'patient_phone_numbers' => [Integrations::Medelement::PatientContactBinding.provider_phone(appointment, authored_phone: appointment.client_phone)]
    ).tap do |snapshot|
      phone = snapshot['patient_phone_numbers'].first
      snapshot['patient'] = {
        'phone_number' => phone, 'phone_numbers' => [phone],
        'payload' => Integrations::Medelement::ProviderCommands::PatientPayloadBuilder.new(
          contact: command.contact, phone_number: phone, organization_id: original['organization_id'],
          identity: { first_name: appointment.client_first_name, last_name: appointment.client_last_name,
                      middle_name: appointment.client_middle_name, iin: appointment.client_identifier,
                      birth_date: appointment.client_birth_date, gender: appointment.client_gender, appointment_owned: true }
        ).build
      }
      snapshot['confirmation']['patient_name'] = appointment.client_name if snapshot['confirmation']
    end
  end

  def refresh_receipt!(original, previous_confirmation)
    builder = Integrations::Medelement::ProviderCommands::RequestSnapshotBuilder
    snapshot = refreshed_snapshot(original)
    validate_refreshed_patient!(original, snapshot)
    builder.validate_schema!(snapshot)
    fingerprint = builder.fingerprint(snapshot)
    receipt = create_selection_receipt!(previous_confirmation, fingerprint)
    state = command.execution_state.to_h.merge(
      'request_snapshot' => snapshot, 'request_fingerprint' => fingerprint, 'confirmation_request_id' => receipt.id,
      'patient_selection_previous_confirmation_id' => previous_confirmation.id,
      'patient_selection_previous_fingerprint' => expected_fingerprint,
      'patient_selection_history' => Array(command.execution_state.to_h['patient_selection_history']) + [{
        'request_snapshot' => original, 'request_fingerprint' => expected_fingerprint,
        'confirmation_request_id' => previous_confirmation.id, 'selected_by_id' => actor.id, 'selected_at' => Time.current.iso8601
      }]
    )
    command.update!(provider_patient_code: patient_code, confirmation_request: receipt, execution_state: state)
    conflict!('The selected patient confirmation could not be bound') unless
      command.request_snapshot_valid? && command.confirmation_matches_request_snapshot? && POLICY.current?(command)
    status = Integrations::Medelement::AppointmentProviderStatus
    status.persist!(appointment, status::PENDING, command: command)
  end

  def validate_refreshed_patient!(original, snapshot)
    return if POLICY.frozen?(original)

    gender = original.dig('patient', 'payload', 'gender')
    return if gender.blank?

    effective_gender = snapshot.dig('patient', 'payload', 'gender')
    conflict!('The confirmed patient gender changed during selection') if effective_gender.blank?
    validate_patient_value!('client_gender', effective_gender, gender)
  end

  def create_selection_receipt!(previous, fingerprint)
    receipt = Confirmations::CreateService.new(
      account: command.account, title: previous.title,
      body: "#{previous.body}\nВыбран пациент: #{appointment.client_name}. Подтверждены только карточка и недостающие данные пациента; параметры приёма сохранены.",
      conversation: previous.conversation, contact: previous.contact, inbox: previous.inbox,
      subject: appointment, requester: previous.requested_by,
      metadata: previous.metadata.to_h.merge(
        'request_fingerprint' => fingerprint, 'supersedes_confirmation_request_id' => previous.id,
        'patient_contact_id' => appointment.patient_contact_id, 'patient_selected_by_id' => actor.id
      ), idempotency_key: "medelement-patient-selection:#{command.id}:#{fingerprint}"
    ).perform
    valid = receipt.account_id == command.account_id && receipt.requested_by_id == previous.requested_by_id &&
            receipt.contact_id == command.contact_id && receipt.subject == appointment &&
            receipt.metadata.to_h['medelement_provider_command_id'].to_s == command.id.to_s &&
            receipt.metadata.to_h['operation'] == command.operation && receipt.metadata.to_h['request_fingerprint'] == fingerprint
    conflict!('The selected patient confirmation has a different intent') unless valid
    if receipt.pending?
      receipt.update!(status: 'confirmed', resolved_at: Time.current, resolved_by: actor, resolution_source: 'manual',
                      resolution_metadata: { 'surface' => 'scheduling_patient_selection', 'previous_confirmation_request_id' => previous.id })
    end
    conflict!('The selected patient confirmation is not confirmed') unless receipt.confirmed? && receipt.resolved_by_id == actor.id
    receipt
  end

  def conflict!(message)
    raise Scheduling::Error.new(code: 'MEDELEMENT_PATIENT_IDENTITY_CONFLICT', message: message, status: :conflict)
  end
end
# rubocop:enable Metrics/ClassLength
