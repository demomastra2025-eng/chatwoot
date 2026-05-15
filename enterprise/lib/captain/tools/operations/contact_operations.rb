class Captain::Tools::Operations::ContactOperations < Captain::Tools::Operations::BaseOperation
  def create_company_for_current_contact(name:, domain: nil, description: nil)
    raise ArgumentError, 'Current contact is not available' if current_contact.blank?
    raise ArgumentError, 'Current contact already has a company' if current_company.present?
    raise ArgumentError, 'Company name is required' if name.blank?

    with_idempotent_creation('create_company', create_company_params(name, domain, description)) do
      company = account.companies.create!(create_company_attributes(name, domain, description))
      current_contact.update!(company: company)
      company.reload
    end
  end

  def update_current_company(name: nil, domain: nil, description: nil)
    raise ArgumentError, 'Current company is not available' if current_company.blank?

    current_company.update!(
      compact_update_attributes(
        name: name,
        domain: domain,
        description: description
      )
    )
    current_company.reload
  end

  def update_current_contact(name: nil, email: nil, phone_number: nil, identifier: nil, custom_attributes: nil)
    raise ArgumentError, 'Current contact is not available' if current_contact.blank?

    update_attributes = compact_update_attributes(
      name: name,
      email: email,
      phone_number: phone_number,
      identifier: identifier
    )

    if custom_attributes.present?
      update_attributes[:custom_attributes] = CustomAttributes::MutationService.merge(
        current_contact.custom_attributes,
        parsed_hash(custom_attributes, field_name: 'custom_attributes')
      )
    end

    current_contact.update!(update_attributes)
    current_contact.reload
  end

  def create_contact(params = {})
    params = params.symbolize_keys
    raise ArgumentError, 'At least one of email, phone_number, or identifier is required' if contact_identifier_blank?(params)

    existing_contact = find_existing_contact(params.slice(:email, :phone_number, :identifier))
    return { contact: existing_contact, status: 'existing' } if existing_contact.present?

    contact = with_idempotent_creation('create_contact', params.slice(*create_contact_keys)) do
      account.contacts.create!(create_contact_attributes(params))
    end

    { contact: contact.reload, status: 'created' }
  end

  def merge_contacts(base_contact_id:, mergee_contact_id:)
    base_contact = account.contacts.find(base_contact_id)
    mergee_contact = account.contacts.find(mergee_contact_id)

    ::ContactMergeAction.new(
      account: account,
      base_contact: base_contact,
      mergee_contact: mergee_contact
    ).perform
  end

  private

  def compact_update_attributes(attributes)
    attributes.each_with_object({}) do |(key, value), memo|
      next if value.nil?

      memo[key] = value.is_a?(String) ? value.strip.presence : value
    end
  end

  def create_company_params(name, domain, description)
    {
      name: name,
      domain: domain,
      description: description,
      contact_id: current_contact.id
    }
  end

  def create_company_attributes(name, domain, description)
    {
      name: name.to_s.strip,
      domain: domain.to_s.strip.presence,
      description: description.to_s.strip.presence
    }
  end

  def create_contact_attributes(params)
    compact_update_attributes(
      name: params[:name],
      email: params[:email],
      phone_number: params[:phone_number],
      identifier: params[:identifier],
      company_id: resolved_company_id(params[:company_id]),
      custom_attributes: parsed_hash(params[:custom_attributes], field_name: 'custom_attributes'),
      additional_attributes: parsed_hash(params[:additional_attributes], field_name: 'additional_attributes')
    )
  end

  def create_contact_keys
    %i[name email phone_number identifier company_id custom_attributes additional_attributes]
  end

  def contact_identifier_blank?(params)
    params.values_at(:email, :phone_number, :identifier).all?(&:blank?)
  end

  def resolved_company_id(company_id)
    return nil if company_id.blank?

    account.companies.find(company_id).id
  end

  def find_existing_contact(params)
    scopes = contact_identifier_scopes(params)
    return nil if scopes.empty?

    scopes.reduce(&:or).order(:id).first
  end

  def contact_identifier_scopes(params)
    %i[email phone_number identifier].filter_map do |key|
      value = params[key]
      next if value.blank?

      account.contacts.where(key => value.to_s.strip)
    end
  end
end
