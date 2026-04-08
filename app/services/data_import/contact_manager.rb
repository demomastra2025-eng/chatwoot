class DataImport::ContactManager
  def initialize(account)
    @account = account
  end

  def build_contact(params)
    contact = find_or_initialize_contact(params)
    update_contact_attributes(params, contact)
    contact
  end

  def find_or_initialize_contact(params)
    contact = find_existing_contact(params)
    contact_params = params.slice(:email, :identifier, :phone_number)
    if contact_params[:phone_number].present?
      contact_params[:phone_number] =
        normalize_phone_number(contact_params[:phone_number]) || contact_params[:phone_number]
    end
    contact ||= @account.contacts.new(contact_params)
    contact
  end

  def find_existing_contact(params)
    contact = find_contact_by_identifier(params)
    contact ||= find_contact_by_email(params)
    contact ||= find_contact_by_phone_number(params)

    update_contact_with_merged_attributes(params, contact) if contact.present? && contact.valid?
    contact
  end

  def find_contact_by_identifier(params)
    return unless params[:identifier]

    @account.contacts.find_by(identifier: params[:identifier])
  end

  def find_contact_by_email(params)
    return unless params[:email]

    @account.contacts.from_email(params[:email])
  end

  def find_contact_by_phone_number(params)
    return unless params[:phone_number]

    normalized_phone_number = normalize_phone_number(params[:phone_number]) || params[:phone_number]
    @account.contacts.find_by(phone_number: normalized_phone_number)
  end

  def update_contact_with_merged_attributes(params, contact)
    contact.identifier = params[:identifier] if params[:identifier].present?
    contact.email = params[:email] if params[:email].present?
    if params[:phone_number].present?
      contact.phone_number = normalize_phone_number(params[:phone_number]) || params[:phone_number]
    end
    update_contact_attributes(params, contact)
    contact.save
  end

  private

  def normalize_phone_number(phone_number)
    ::Contacts::PhoneNumberNormalizer.normalize(phone_number)
  end

  def update_contact_attributes(params, contact)
    contact.name = params[:name] if params[:name].present?
    contact.additional_attributes ||= {}
    contact.additional_attributes[:company] = params[:company] if params[:company].present?
    contact.additional_attributes[:city] = params[:city] if params[:city].present?
    contact.assign_attributes(custom_attributes: contact.custom_attributes.merge(params.except(:identifier, :email, :name, :phone_number)))
  end
end
