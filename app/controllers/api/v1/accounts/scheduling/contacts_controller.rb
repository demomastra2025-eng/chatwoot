class Api::V1::Accounts::Scheduling::ContactsController < Api::V1::Accounts::Scheduling::BaseController
  before_action :set_contact, only: [:update]

  def index
    contacts = Current.account.contacts.order(created_at: :desc)
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

  def apply_search(scope)
    return scope if params[:search].blank?

    search = "%#{params[:search].strip}%"
    scope.where(
      'contacts.name ILIKE :search OR contacts.email ILIKE :search OR contacts.phone_number ILIKE :search OR contacts.identifier ILIKE :search',
      search: search
    )
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
