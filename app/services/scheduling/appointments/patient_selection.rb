class Scheduling::Appointments::PatientSelection
  def initialize(account:, appointment:, contact:, params:, actor:)
    @account = account
    @appointment = appointment
    @contact = contact
    @params = params
    @actor = actor
  end

  def perform
    return unless params.key?(:patient_contact_id)

    conflict!('A patient card must be selected') if params[:patient_contact_id].blank?
    conflict!('Patient selection requires an authorized account actor') unless authorized_actor?
    Contacts::PhoneIdentityLock.acquire!(account_id: account.id)
    card = account.contacts.lock.find(params[:patient_contact_id])
    conflict!('Select a recorded patient card') unless recorded_card?(card)
    validate_recorded_references!(card)
    validate_communication_patient!(card) if card.id == contact&.id
    validate_current_target!(card)
    validate_identifier!(card)
    apply_card_defaults!(card)
    validate_linked_identity!
    attributes = appointment.custom_attributes.to_h.merge(policy::OWNED_IDENTITY_KEY => true)
    attributes = attributes.except('medelement_patient_code')
    code = card.custom_attributes.to_h['medelement_patient_code'].presence
    attributes['medelement_patient_code'] = code if code
    appointment.custom_attributes = attributes
    card
  end

  private

  attr_reader :account, :appointment, :contact, :params, :actor

  def policy = Integrations::Medelement::AppointmentPatientIdentity

  def authorized_actor?
    return account.users.exists?(id: actor.id) if actor.is_a?(User)
    return false unless defined?(Captain::Assistant) && actor.is_a?(Captain::Assistant) && actor.account_id == account.id

    Captain::Tools::Agent::AppointmentAccess.valid_patient_selection?(
      token: params[:patient_selection_token], assistant: actor, contact: contact, patient_id: params[:patient_contact_id]
    )
  end

  def recorded_card?(card)
    Contacts::SharedPhone.card_identity_recorded?(card) || Scheduling::IinValidator.valid?(card.custom_attributes.to_h['medelement_iin'])
  end

  def validate_recorded_references!(card)
    selected = card.custom_attributes.to_h['medelement_patient_code'].to_s.presence
    recorded = [appointment.custom_attributes.to_h['medelement_patient_code'],
                appointment.patient_contact&.custom_attributes.to_h['medelement_patient_code']].filter_map { |code| code.to_s.presence }
    conflict!('The recorded provider references identify another patient') if recorded.any? { |code| code != selected }
  end

  def validate_communication_patient!(card)
    attributes = card.custom_attributes.to_h
    verified = attributes['medelement_patient_code'].present? && Scheduling::IinValidator.valid?(attributes['medelement_iin'])
    conflict!('The communication contact is not a verified patient card') unless verified
    known = Scheduling::IinValidator.normalize(attributes['medelement_iin'])
    conflicting = [card.identifier, attributes['iin']].any? do |value|
      Scheduling::IinValidator.valid?(value) && Scheduling::IinValidator.normalize(value) != known
    end
    conflict!('The communication contact has conflicting recorded patient identifiers') if conflicting
  end

  def validate_current_target!(card)
    return if appointment.new_record? || appointment.patient_contact_id == card.id

    linked = appointment.external_ref.to_s.start_with?('medelement:reception:') ||
             appointment.custom_attributes.to_h['medelement_reception_code'].present?
    commands = Integrations::Medelement::ProviderCommand.where(account_id: account.id, appointment_id: appointment.id)
    blocked = linked || commands.any?(&:provider_write_started?) ||
              Integrations::Medelement::AppointmentPatientBindingSnapshot.writes_in_flight([appointment.id]).exists?
    conflict!('The recorded appointment patient cannot be changed after a provider write starts') if blocked
  end

  def validate_identifier!(card)
    known = policy.contact_iin(card)
    if known.present? && params.key?(:client_identifier) && Scheduling::IinValidator.normalize(params[:client_identifier]).blank?
      conflict!('The selected patient recorded IIN cannot be cleared')
    end
    values = [params[:client_identifier], appointment.client_identifier].filter_map { |value| Scheduling::IinValidator.normalize(value).presence }
    conflict!('The selected card does not match the recorded patient IIN') if known.present? && values.any? { |value| value != known }
    return unless known.present?

    names = policy.contact_names(card)
    policy::NAME_KEYS.each do |key|
      field = "client_#{key}".to_sym
      next unless params.key?(field) && params[field].present? && names[key].present?
      next if policy.normalize(field.to_s, params[field]) == policy.normalize(field.to_s, names[key])

      conflict!('The selected card does not match the authored patient name')
    end
  end

  def validate_linked_identity!
    identity = policy::NAME_KEYS.index_with { |key| params["client_#{key}".to_sym] }.symbolize_keys
    Integrations::Medelement::AppointmentPatientIdentityDecision.new(
      appointment: appointment, contact: contact, params: params, identity: identity, mapped: false
    ).validate_selected!
  end

  def apply_card_defaults!(card)
    names = policy.contact_names(card)
    policy::NAME_KEYS.each { |key| params["client_#{key}".to_sym] = names[key] unless params.key?("client_#{key}".to_sym) }
    params[:client_identifier] = policy.contact_iin(card) unless params.key?(:client_identifier)
    params[:client_birth_date] = card.custom_attributes.to_h['medelement_birth_date'].presence || card.custom_attributes.to_h['birth_date'] unless params.key?(:client_birth_date)
    params[:client_gender] = card.custom_attributes.to_h['medelement_gender'].presence || card.custom_attributes.to_h['gender'] unless params.key?(:client_gender)
    params[:client_name] = [params[:client_first_name], params[:client_last_name], params[:client_middle_name]].compact_blank.join(' ')
    params[:client_phone] = appointment.client_phone.presence || card.phone_number.presence || Contacts::SharedPhone.share_of(card)&.phone ||
                            contact&.phone_number unless params.key?(:client_phone)
  end

  def conflict!(message)
    raise Scheduling::Error.new(code: 'MEDELEMENT_PATIENT_IDENTITY_CONFLICT', message: message, status: :conflict)
  end
end
