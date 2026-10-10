# Synthetic contact/company handlers. IDs are decoded/encoded only by ToolExecutor's
# session namespace. Native record objects below are unsaved payload projections.
module Captain::Playground::ContactCompanyTools
  CONTACT_COMPANY_ARGUMENTS = {
    'get_contact' => %w[contact_id], 'search_contacts' => %w[email phone_number name limit],
    'update_contact' => %w[name email phone_number identifier custom_attributes],
    'get_company' => %w[company_id], 'search_companies' => %w[name domain limit],
    'create_company' => %w[name domain description], 'update_company' => %w[name domain description]
  }.freeze
  CONTACT_PROJECTION_FIELDS = %w[id name last_name middle_name email phone_number identifier company_id contact_type blocked
                                 country_code location additional_attributes custom_attributes created_at updated_at last_activity_at].freeze
  COMPANY_PROJECTION_FIELDS = %w[id name domain description additional_attributes custom_attributes created_at updated_at last_activity_at].freeze

  private

  def contact_details
    contact_company_arguments!
    raise ArgumentError, 'Record is not available' unless @args.fetch('contact_id').to_s == caller['id'].to_s

    { contact: native_contact_payload(caller, Captain::Tools::Copilot::GetContactService) }
  end

  def search_contacts
    contact_company_arguments!
    # Agent::PatientScope.contacts contains only the conversation contact. Family
    # patient access remains the separate appointment/IIN workflow.
    records = [caller].select do |record|
      (@args['email'].blank? || record['email'] == @args['email']) &&
        (@args['phone_number'].blank? || record['phone_number'] == @args['phone_number']) &&
        (@args['name'].blank? || synthetic_ilike?(record['name'], @args['name']))
    end
    { filters: @args.slice('email', 'phone_number', 'name'), total_count: records.size,
      contacts: records.first(contact_company_limit).map { |record| native_contact_payload(record, Captain::Tools::Copilot::SearchContactsService) } }
  end

  def update_contact
    contact_company_arguments!
    operations = Captain::Tools::Operations::ContactOperations.allocate
    fields = operations.send(:compact_update_attributes, @args.slice('name', 'email', 'phone_number', 'identifier').symbolize_keys)
    fields.delete(:phone_number) if synthetic_reserved_phone?(fields[:phone_number])
    if @args['custom_attributes'].present?
      incoming = operations.send(:parsed_hash, @args['custom_attributes'], field_name: 'custom_attributes')
      fields[:custom_attributes] = CustomAttributes::MutationService.merge(caller['custom_attributes'], Contacts::ServerOwnedAttributes.strip(incoming))
    end
    candidate = contact_projection(caller.merge(fields.stringify_keys))
    candidate.send(:prepare_contact_attributes)
    candidate.send(:normalize_phone_number)
    candidate.send(:sync_contact_attributes)
    validate_contact_company_projection!(candidate, %i[email phone_number identifier])
    validate_synthetic_contact_uniqueness!(candidate)
    attributes = candidate.attributes.slice(*CONTACT_PROJECTION_FIELDS).deep_stringify_keys
    attributes['updated_at'] = Time.current.iso8601 if attributes.except('created_at', 'updated_at') !=
                                                    contact_projection(caller).attributes.slice(*CONTACT_PROJECTION_FIELDS).except('created_at', 'updated_at')
    caller.merge!(attributes)
    { action: 'update_contact', contact: native_contact_payload(caller, Captain::Tools::Copilot::UpdateContactService), simulated: true }
  end

  def company_details
    contact_company_arguments!
    { company: Crm::PayloadBuilder.company(company_projection(record!('companies', @args.fetch('company_id')))).deep_dup }
  end

  def search_companies
    contact_company_arguments!
    records = @data.fetch('companies').select do |record|
      (@args['name'].blank? || synthetic_ilike?(record['name'], @args['name'])) &&
        (@args['domain'].blank? || synthetic_ilike?(record['domain'], @args['domain']))
    end.sort_by { |record| [record['name'].to_s, record['id'].to_i] }
    { filters: @args.slice('name', 'domain'), total_count: records.size,
      companies: records.first(contact_company_limit).map { |record| Crm::PayloadBuilder.company(company_projection(record)).deep_dup } }
  end

  def create_company
    contact_company_arguments!
    raise ArgumentError, 'Current contact already has a company' if caller['company_id'].present?
    raise ArgumentError, 'Company name is required' if @args.fetch('name').blank?
    raise ArgumentError, 'Scenario company limit reached' if @data.fetch('companies').size >= Captain::Playground::Scenario::MAX_RECORDS

    attributes = Captain::Tools::Operations::ContactOperations.allocate.send(
      :create_company_attributes, @args['name'], @args['domain'], @args['description']
    )
    candidate = company_projection(attributes.stringify_keys)
    normalize_and_validate_company!(candidate)
    timestamp = Time.current.iso8601
    record = candidate.attributes.slice(*COMPANY_PROJECTION_FIELDS).merge('id' => @scenario.next_id!,
                                                                          'created_at' => timestamp, 'updated_at' => timestamp)
    @data.fetch('companies') << record
    caller['company_id'] = record['id']
    caller['updated_at'] = timestamp
    Crm::ToolPayloadBuilder.company_payload(action: 'create_company', company: company_projection(record)).merge(simulated: true)
  end

  def update_company
    contact_company_arguments!
    raise ArgumentError, 'Current company is not available' if caller['company_id'].blank?

    record = record!('companies', caller['company_id'])
    attributes = Captain::Tools::Operations::ContactOperations.allocate.send(:compact_update_attributes, @args.symbolize_keys)
    candidate = company_projection(record.merge(attributes.stringify_keys))
    normalize_and_validate_company!(candidate)
    normalized = candidate.attributes.slice(*COMPANY_PROJECTION_FIELDS)
    normalized['updated_at'] = Time.current.iso8601 if normalized.except('created_at', 'updated_at') !=
                                                    company_projection(record).attributes.slice(*COMPANY_PROJECTION_FIELDS).except('created_at', 'updated_at')
    record.merge!(normalized)
    Crm::ToolPayloadBuilder.company_payload(action: 'update_company', company: company_projection(record)).merge(simulated: true)
  end

  def contact_company_arguments!
    unknown = @args.keys - CONTACT_COMPANY_ARGUMENTS.fetch(@tool_id)
    raise ArgumentError, "Unsupported #{@tool_id} arguments: #{unknown.join(', ')}" if unknown.any?
  end

  def contact_company_limit
    Captain::Tools::Copilot::BaseAccountTool.allocate.send(:parse_limit, @args['limit'])
  end

  def native_contact_payload(record, service)
    service.allocate.send(:contact_payload, contact_projection(record)).deep_dup
  end

  def contact_projection(record)
    Contact.new(record.slice(*CONTACT_PROJECTION_FIELDS).merge('account_id' => @session.account.id)).tap do |contact|
      company = @data.fetch('companies').find { |item| item['id'].to_s == record['company_id'].to_s } if record['company_id'].present?
      association = contact.association(:company)
      association.target = company && company_projection(company)
      association.loaded!
    end
  end

  def company_projection(record)
    Company.new(record.slice(*COMPANY_PROJECTION_FIELDS).merge('account_id' => @session.account.id,
                                                              'contacts_count' => synthetic_company_contacts_count(record['id'])))
  end

  def synthetic_company_contacts_count(id)
    return 0 if id.blank?

    ids = @data.fetch('contacts').select { |record| record['company_id'].to_s == id.to_s }.map { |record| record['id'] }
    @data.fetch('deals').select { |record| record['company_id'].to_s == id.to_s }.each do |deal|
      ids.concat(Array(deal['deal_contacts']).filter_map { |link| link['contact_id'] })
      ids << deal['contact_id'] if deal['contact_id']
    end
    ids.uniq.size
  end

  def normalize_and_validate_company!(candidate)
    candidate.send(:prepare_company_attributes)
    candidate.send(:normalize_domain)
    validate_contact_company_projection!(candidate, %i[name domain description custom_attributes])
    return if candidate.domain.blank?
    return unless @data.fetch('companies').any? { |record| record['id'] != candidate.id && record['domain'].to_s.strip.downcase == candidate.domain }

    candidate.errors.add(:domain, :taken)
    raise ArgumentError, candidate.errors.full_messages.join(', ')
  end

  def validate_contact_company_projection!(candidate, fields)
    fields.flat_map { |field| candidate.class.validators_on(field) }.uniq.each do |validator|
      next if validator.kind == :uniqueness

      validator.validate(candidate)
    end
    raise ArgumentError, candidate.errors.full_messages.join(', ') if candidate.errors.any?
  end

  def validate_synthetic_contact_uniqueness!(candidate)
    others = @data.fetch('contacts').reject { |record| record['id'] == candidate.id }
    %w[email phone_number identifier].each do |field|
      value = candidate.public_send(field)
      next if value.blank?
      next unless others.any? { |record| field == 'email' ? record[field].to_s.downcase == value.downcase : record[field] == value }

      candidate.errors.add(field, :taken)
    end
    raise ArgumentError, candidate.errors.full_messages.join(', ') if candidate.errors.any?
  end

  def synthetic_reserved_phone?(phone)
    return false if phone.blank?

    normalized = Contacts::ServerOwnedAttributes.normalized_phone(phone)
    @data.fetch('contacts').any? do |record|
      attributes = record['custom_attributes'].to_h
      next false unless attributes[Contacts::SharedPhone::SHARED_PHONE_KEY] == normalized &&
                        Array(attributes[Contacts::SharedPhone::SECONDARY_PHONES_KEY]).include?(normalized)

      owner_id = attributes[Contacts::SharedPhone::SHARED_OWNER_KEY].to_i
      owner = @data.fetch('contacts').find { |item| item['id'] == owner_id }
      hidden_other = attributes[Contacts::SharedPhone::SHARED_VIA_KEY] == Contacts::SharedPhone::VIA_BOOKING_CHAT &&
                     owner && owner['phone_number'].blank? && owner_id != caller['id']
      hidden_other || (record['id'] != caller['id'] && owner_id != caller['id'])
    end
  end

  # Match PostgreSQL's unescaped ILIKE wildcard/escape contract. Searches use
  # %query% in production; literal email/phone filters above stay case sensitive.
  def synthetic_ilike?(value, query)
    return false if value.nil?

    tokens = []
    escaped = false
    "%#{query.to_s.downcase}%".each_char do |character|
      if escaped
        tokens << Regexp.escape(character)
        escaped = false
      elsif character == '\\'
        escaped = true
      else
        tokens << { '%' => '.*', '_' => '.' }.fetch(character) { Regexp.escape(character) }
      end
    end
    Regexp.new("\\A#{tokens.join}\\z", Regexp::MULTILINE).match?(value.to_s.downcase)
  end
end
