class Api::V1::Accounts::Scheduling::ContactsController < Api::V1::Accounts::Scheduling::BaseController
  before_action :set_contact, only: [:update, :patients, :create_patient]
  before_action :ensure_patient_context_employee!, only: [:patients, :create_patient]

  def patients
    cards = Scheduling::PatientContextQuery.new(account: Current.account, contact: @contact).patients
    render_payload({ contact_id: @contact.id, patients: cards.map { |card| patient_payload(card) } })
  end

  def create_patient
    attrs = params.permit(:first_name, :name, :last_name, :middle_name, :iin, :identifier, :birth_date, :gender,
                          :phone, :phone_number, :conversation_id, :conversation_display_id, :idempotency_key)
    card = Scheduling::PatientContactCreationService.new(account: Current.account, contact: @contact, params: attrs).perform
    render_payload(patient_payload(card), status: :created)
  end

  def index
    contacts = Current.account.contacts.order(created_at: :desc)
    contacts = contacts.where(id: params[:contact_id]) if params[:contact_id].present?
    contacts = apply_search(contacts)
    contacts = contacts.limit(limit_param)

    render_payload(
      contacts.map { |contact| Scheduling::PayloadBuilder.contact(contact) },
      meta: { count: contacts.size }
    )
  end

  def create
    contact = Current.account.contacts.new(contact_attributes)
    contact.custom_attributes = contact_custom_attributes(contact)
    validate_required_contact_fields!
    contact.save!

    render_payload(Scheduling::PayloadBuilder.contact(contact), status: :created)
  end

  def update
    @contact.assign_attributes(contact_attributes)
    @contact.custom_attributes = contact_custom_attributes(@contact)
    validate_required_contact_fields!
    @contact.save!

    render_payload(Scheduling::PayloadBuilder.contact(@contact))
  end

  private

  def ensure_patient_context_employee!
    return if Current.user.is_a?(User) && Current.account.users.exists?(id: Current.user.id)

    raise Scheduling::Error.new(code: 'PATIENT_CONTEXT_EMPLOYEE_REQUIRED', message: 'Patient context requires an account employee', status: :forbidden)
  end

  def patient_payload(card)
    selectable = Contacts::SharedPhone.card_identity_recorded?(card) || Scheduling::IinValidator.valid?(card.custom_attributes.to_h['medelement_iin'])
    owner_patient = card.id == @contact.id && card.custom_attributes.to_h['medelement_patient_code'].present? &&
                    Scheduling::IinValidator.valid?(card.custom_attributes.to_h['medelement_iin'])
    phone = card.phone_number.presence || Contacts::SharedPhone.share_of(card)&.phone
    Scheduling::PayloadBuilder.contact(card).merge(patient_identity_payload(card)).merge(
      patient_contact_id: selectable && (card.id != @contact.id || owner_patient) ? card.id : nil,
      selectable_patient: selectable,
      phone: phone,
      communication_contact_id: @contact.id
    )
  end

  # The patient selector projects the recorded clinical identity; the communication
  # contact may retain a messenger alias and must not be rewritten to show this data.
  def patient_identity_payload(card)
    policy = Integrations::Medelement::AppointmentPatientIdentity
    attributes = card.custom_attributes.to_h
    names = policy.contact_names(card)
    {
      full_name: policy::NAME_KEYS.filter_map { |key| names[key].presence }.join(' '),
      first_name: names['first_name'], last_name: names['last_name'], middle_name: names['middle_name'],
      identifier: policy.contact_iin(card) || card.identifier.presence || attributes['iin'],
      birth_date: patient_birth_date(attributes),
      gender: attributes['medelement_gender'].presence || attributes['gender']
    }
  end

  def patient_birth_date(attributes)
    value = attributes['medelement_birth_date'].presence || attributes['birth_date'].presence
    Date.parse(value.to_s).iso8601 if value
  rescue Date::Error
    nil
  end

  def apply_search(scope)
    return scope if params[:search].blank?

    Search::ContactQuery.new(params[:search]).apply(scope)
  end

  def contact_attributes
    attrs = params.permit(:name, :full_name, :first_name, :last_name, :middle_name, :phone, :phone_number, :identifier, :company_id)
    iin = normalized_iin

    {
      name: attrs[:first_name].presence || attrs[:full_name].presence || attrs[:name].presence,
      last_name: attrs[:last_name].presence,
      middle_name: attrs[:middle_name].presence,
      phone_number: normalize_phone(attrs[:phone].presence || attrs[:phone_number].presence),
      identifier: attrs[:identifier].presence || iin,
      company_id: resolve_company_id(attrs[:company_id])
    }.compact
  end

  def contact_custom_attributes(contact)
    incoming = params.permit(:birth_date, :gender, :iin, custom_attributes: {})[:custom_attributes] || {}
    Integrations::Medelement::ProviderOwnedAttributesGuard.validate!(
      incoming: incoming,
      current: contact.custom_attributes
    )
    merged = CustomAttributes::MutationService.merge(contact.custom_attributes, incoming)
    merged['birth_date'] = params[:birth_date] if params[:birth_date].present?
    merged['gender'] = params[:gender] if params[:gender].present?
    merged['iin'] = normalized_iin if normalized_iin.present?
    merged
  end

  def limit_param
    value = params[:limit].presence || 20
    value.to_i.clamp(1, 100)
  end

  def normalize_phone(raw)
    return if raw.blank?

    phone = raw.to_s.strip
    return phone if phone.match?(/\+[1-9]\d{7,14}\z/)

    digits = phone.gsub(/\D/, '')
    return "+7#{digits}" if digits.length == 10
    return "+7#{digits[1..10]}" if digits.length >= 11 && %w[7 8].include?(digits[0])

    phone
  end

  def normalized_iin
    @normalized_iin ||= Scheduling::IinValidator.normalize(required_iin_value)
  end

  def validate_required_last_name!
    last_name = params.key?(:last_name) ? params[:last_name] : @contact&.last_name
    return if last_name.present?

    raise Scheduling::Error.new(
      code: 'CLIENT_LAST_NAME_REQUIRED',
      message: 'Last name is required',
      status: :unprocessable_content
    )
  end

  def validate_required_contact_fields!
    return if action_name == 'update' && !contact_identity_update?

    validate_required_iin!
    validate_required_last_name! if medelement_identity_required?
  end

  def validate_required_iin!
    if required_iin_value.blank?
      return unless medelement_identity_required?

      raise Scheduling::Error.new(code: 'IIN_REQUIRED', message: 'IIN is required', status: :unprocessable_content)
    end

    return if Scheduling::IinValidator.valid?(normalized_iin)

    raise Scheduling::Error.new(code: 'INVALID_IIN', message: 'Invalid IIN', status: :unprocessable_content)
  end

  def required_iin_value
    params[:iin].presence || @contact&.custom_attributes&.dig('iin') || @contact&.identifier
  end

  def contact_identity_update?
    %w[first_name last_name middle_name full_name phone phone_number iin].any? { |key| params.key?(key) }
  end

  def medelement_identity_required?
    resource_requires_medelement_identity = medelement_resource?
    provider_managed_contact? || resource_requires_medelement_identity
  end

  def provider_managed_contact?
    @contact&.custom_attributes&.dig('medelement_patient_code').present?
  end

  def medelement_resource?
    return false if params[:resource_id].blank?

    resource = Current.account.scheduling_resources.find(params[:resource_id])
    resource.custom_attributes['medelement_specialist_code'].present?
  end

  def resolve_company_id(company_id)
    return if company_id.blank?

    Current.account.companies.find(company_id).id
  end

  def set_contact
    @contact = Current.account.contacts.find(params[:id])
  end
end
