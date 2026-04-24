class Captain::Tools::Copilot::SearchContactsService < Captain::Tools::Copilot::BaseAccountTool
  def self.name
    'search_contacts'
  end

  description 'Search contacts by name, email, or phone number'
  param :email, type: :string, desc: 'Filter contacts by email', required: false
  param :phone_number, type: :string, desc: 'Filter contacts by phone number', required: false
  param :name, type: :string, desc: 'Filter contacts by name (partial match)', required: false
  param :limit, type: :number, desc: 'Maximum number of contacts to return', required: false

  def execute(email: nil, phone_number: nil, name: nil, limit: nil)
    contacts = account.contacts.order(:name, :id)
    contacts = contacts.where(email: email) if email.present?
    contacts = contacts.where(phone_number: phone_number) if phone_number.present?
    contacts = contacts.where('LOWER(name) ILIKE ?', "%#{name.to_s.downcase}%") if name.present?

    total_count = contacts.count
    records = contacts.limit(parse_limit(limit)).map { |contact| contact_payload(contact) }

    formatted_payload(
      filters: {
        email: email,
        phone_number: phone_number,
        name: name
      }.compact,
      total_count: total_count,
      contacts: records
    )
  end

  def active?
    user_has_permission('contact_manage')
  end

  private

  def contact_payload(contact)
    {
      id: contact.id,
      name: contact.name,
      email: contact.email,
      phone_number: contact.phone_number,
      identifier: contact.identifier,
      company_id: contact.company_id,
      created_at: contact.created_at&.iso8601,
      updated_at: contact.updated_at&.iso8601
    }
  end
end
