class Captain::Tools::Operations::ContactOperations < Captain::Tools::Operations::BaseOperation
  def create_company_for_current_contact(name:, domain: nil, description: nil)
    raise ArgumentError, 'Current contact is not available' if current_contact.blank?
    raise ArgumentError, 'Current contact already has a company' if current_company.present?
    raise ArgumentError, 'Company name is required' if name.blank?

    with_idempotent_creation(
      'create_company',
      {
        name: name,
        domain: domain,
        description: description,
        contact_id: current_contact.id
      }
    ) do
      company = account.companies.create!(
        name: name.to_s.strip,
        domain: domain.to_s.strip.presence,
        description: description.to_s.strip.presence
      )
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
end
