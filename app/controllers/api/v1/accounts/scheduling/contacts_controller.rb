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
    validate_phone_update!
    @contact.save!

    render_payload(Scheduling::PayloadBuilder.contact(@contact))
  end

  private

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
    attrs = params.permit(:name, :full_name, :first_name, :last_name, :middle_name, :phone, :phone_number, :identifier,
                          :company_id, :notifications_muted)
    attributes = {
      name: resolved_contact_name(attrs),
      last_name: attrs[:last_name].to_s.strip.presence,
      middle_name: attrs[:middle_name].to_s.strip.presence,
      phone_number: resolved_phone_number(attrs),
      identifier: resolved_identifier(attrs),
      company_id: resolve_company_id(attrs[:company_id])
    }.compact.merge(cleared_structured_name_attributes(attrs))
    return attributes unless params.key?(:notifications_muted)

    attributes.merge(notifications_muted: ActiveModel::Type::Boolean.new.cast(attrs[:notifications_muted]))
  end

  def resolved_phone_number(attrs)
    phone = normalize_phone(attrs[:phone].presence || attrs[:phone_number].presence)
    return if phone.blank? || shared_phone_matches_contact?(phone)

    phone
  end

  def shared_phone_matches_contact?(phone)
    @contact&.persisted? && @contact.phone_number.blank? && Contacts::SharedPhone.share_of(@contact)&.phone == phone
  end

  def resolved_identifier(attrs)
    return attrs[:identifier].presence if attrs[:identifier].present?

    normalized_iin if params.key?(:iin) || @contact&.identifier.blank?
  end

  def cleared_structured_name_attributes(attrs)
    return {} unless @contact

    %i[last_name middle_name].index_with { nil }.select { |key, _| params.key?(key) && attrs[key].to_s.strip.blank? }
  end

  def resolved_contact_name(attrs)
    raw = attrs[:first_name].to_s.strip.presence || (@contact&.name.blank? ? attrs[:full_name].presence || attrs[:name].presence : nil)
    Contact.strip_structured_name_suffix(
      raw,
      params.key?(:middle_name) ? attrs[:middle_name] : @contact&.middle_name,
      params.key?(:last_name) ? attrs[:last_name] : @contact&.last_name
    )
  end

  def contact_custom_attributes(contact)
    incoming = params.permit(:birth_date, :gender, :iin, custom_attributes: {})[:custom_attributes] || {}
    Integrations::Medelement::ProviderOwnedAttributesGuard.validate!(
      incoming: incoming,
      current: contact.custom_attributes
    )
    Scheduling::BirthDate.validate_attributes!(incoming, current: contact.custom_attributes)
    birth_date = Scheduling::BirthDate.validate!(params[:birth_date], plain: true)
    merged = CustomAttributes::MutationService.merge(contact.custom_attributes, incoming)
    merged['birth_date'] = birth_date if birth_date.present?
    merged['gender'] = params[:gender] if params[:gender].present?
    merged['iin'] = normalized_iin if should_assign_custom_iin?(contact, merged)
    sync_medelement_identity_attributes!(contact, merged, birth_date: birth_date)
    merged
  end

  def should_assign_custom_iin?(contact, merged)
    normalized_iin.present? && (params.key?(:iin) || merged['iin'].present? || !contact.persisted?)
  end

  def sync_medelement_identity_attributes!(contact, merged, birth_date:)
    sync_medelement_name_attributes!(contact, merged)
    merged['medelement_birth_date'] = birth_date if birth_date.present? && merged.key?('medelement_birth_date')
    merged['medelement_gender'] = params[:gender] if params[:gender].present? && merged.key?('medelement_gender')
    merged['medelement_iin'] = normalized_iin if params.key?(:iin) && normalized_iin.present? && merged.key?('medelement_iin')
  end

  def sync_medelement_name_attributes!(contact, merged)
    return if %w[medelement_first_name medelement_last_name medelement_middle_name].none? { |key| merged[key].present? }

    merged['medelement_first_name'] = contact.name if name_param_present? && contact.name.present?
    merged['medelement_last_name'] = contact.last_name if params.key?(:last_name)
    merged['medelement_middle_name'] = contact.middle_name if params.key?(:middle_name)
  end

  def name_param_present?
    params.key?(:first_name) || params.key?(:name) || params.key?(:full_name)
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
    last_name = if params.key?(:last_name)
                  params[:last_name]
                else
                  @contact&.last_name.presence || @contact&.custom_attributes&.dig('medelement_last_name')
                end
    return if last_name.present?

    raise Scheduling::Error.new(
      code: 'CLIENT_LAST_NAME_REQUIRED',
      message: 'Last name is required',
      status: :unprocessable_content
    )
  end

  def validate_required_middle_name!
    middle_name = if params.key?(:middle_name)
                    params[:middle_name]
                  else
                    @contact&.middle_name.presence || @contact&.custom_attributes&.dig('medelement_middle_name')
                  end
    return if middle_name.present?

    raise Scheduling::Error.new(
      code: 'CLIENT_MIDDLE_NAME_REQUIRED',
      message: 'Middle name is required',
      status: :unprocessable_content
    )
  end

  def validate_required_birth_date!
    incoming_custom = params[:custom_attributes]
    custom_birth_date = incoming_custom[:birth_date] if incoming_custom.respond_to?(:[])
    birth_date = if params.key?(:birth_date)
                   params[:birth_date]
                 elsif incoming_custom.respond_to?(:key?) && incoming_custom.key?(:birth_date)
                   custom_birth_date
                 else
                   @contact&.custom_attributes&.dig('birth_date').presence ||
                     @contact&.custom_attributes&.dig('medelement_birth_date')
                 end
    return if birth_date.present?

    raise Scheduling::Error.new(
      code: 'CLIENT_BIRTH_DATE_REQUIRED',
      message: 'Birth date is required',
      status: :unprocessable_content
    )
  end

  def medelement_configuration
    @medelement_configuration ||= Integrations::Medelement::Configuration.for_account(Current.account)
  end

  def validate_required_contact_fields!
    return if action_name == 'update' && phone_only_update?
    return if action_name == 'update' && !contact_identity_update?

    validate_required_iin!
    return unless medelement_identity_required?

    validate_required_last_name! if medelement_configuration&.require_patient_last_name?
    validate_required_middle_name! if medelement_configuration&.require_patient_middle_name?
    validate_required_birth_date! if medelement_configuration&.require_patient_birth_date?
  end

  def validate_required_iin!
    if required_iin_value.blank?
      return unless medelement_identity_required? && medelement_configuration&.require_patient_iin?

      raise Scheduling::Error.new(code: 'IIN_REQUIRED', message: 'IIN is required', status: :unprocessable_content)
    end

    return if Scheduling::IinValidator.valid?(normalized_iin)

    raise Scheduling::Error.new(code: 'INVALID_IIN', message: 'Invalid IIN', status: :unprocessable_content)
  end

  def required_iin_value
    params[:iin].presence || existing_contact_iin
  end

  def existing_contact_iin
    attrs = @contact&.custom_attributes || {}
    attrs['iin'] || attrs['medelement_iin'] || @contact&.identifier
  end

  def contact_identity_update?
    keys = %w[first_name last_name middle_name full_name phone phone_number iin]
    keys << 'birth_date' if medelement_identity_required? && medelement_configuration&.require_patient_birth_date?
    keys.any? { |key| params.key?(key) }
  end

  def phone_only_update?
    (params.key?(:phone) || params.key?(:phone_number)) &&
      %w[first_name last_name middle_name full_name name iin identifier birth_date gender custom_attributes company_id].none? do |key|
        params.key?(key)
      end
  end

  def validate_phone_update!
    return unless phone_change_requested?
    return if shared_phone_matches_contact?(normalize_phone(params[:phone].presence || params[:phone_number]))

    validate_provider_phone!
    validate_unique_phone!
  end

  def phone_change_requested?
    params.key?(:phone) || params.key?(:phone_number)
  end

  def validate_provider_phone!
    return unless provider_managed_contact? && !@contact.phone_number.to_s.match?(/\A\+7\d{10}\z/)

    raise Scheduling::Error.new(code: 'MEDELEMENT_PATIENT_PHONE_INVALID', message: 'Invalid Kazakhstan phone number',
                                status: :unprocessable_content)
  end

  def validate_unique_phone!
    return if @contact.phone_number.blank? || !@contact.will_save_change_to_phone_number?
    return unless Current.account.contacts.where(phone_number: @contact.phone_number).where.not(id: @contact.id).exists?

    raise Scheduling::Error.new(code: 'CONTACT_PHONE_TAKEN', message: 'Phone number belongs to another contact', status: :conflict)
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
