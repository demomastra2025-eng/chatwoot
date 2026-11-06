class Captain::Tools::Account::SearchContactsService < Captain::Tools::Account::BaseAccountTool
  def self.name
    'search_contacts'
  end

  description 'Search contacts by partial name or full name in Cyrillic or Latin, email, or phone number. ' \
              'A phone number is not required. If several contacts match, use the candidates to clarify which contact is intended.'
  param :email, type: :string, desc: 'Filter contacts by email', required: false
  param :phone_number, type: :string, desc: 'Filter contacts by phone number', required: false
  param :name, type: :string, desc: 'Partial name or full name in any order, Cyrillic or Latin (for example, Алмас or Almas)', required: false
  param :limit, type: :number, desc: 'Maximum number of contacts to return', required: false

  def execute(email: nil, phone_number: nil, name: nil, limit: nil)
    contacts = (patient_scope ? patient_scope.contacts : account.contacts).order(:name, :id)
    contacts = contacts.where(email: email) if email.present?
    contacts = filter_by_phone(contacts, phone_number) if phone_number.present?
    contacts = Search::ContactNameQuery.new(name).apply(contacts) if name.present?

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

  def filter_by_phone(contacts, phone_number)
    matched_ids = Contacts::PhoneLookup.matching_contact_ids(account, phone_number)
    contacts.where(phone_number: phone_number).or(contacts.where(id: matched_ids))
  end

  def contact_payload(contact)
    {
      id: contact.id,
      name: contact.name,
      last_name: contact.last_name,
      middle_name: contact.middle_name,
      display_full_name: contact.display_full_name,
      email: contact.email,
      phone_number: contact.phone_number,
      identifier: Scheduling::IinValidator.tokenize_or_sanitize_identifier(contact.identifier),
      company_id: contact.company_id,
      created_at: contact.created_at&.iso8601,
      updated_at: contact.updated_at&.iso8601
    }
  end
end
