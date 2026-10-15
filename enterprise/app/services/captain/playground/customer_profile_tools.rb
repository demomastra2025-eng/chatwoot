# frozen_string_literal: true

# Synthetic adapters of the customer-scoped profile tools (get_my_contact, update_my_contact, list_my_deals).
# They answer from the scenario caller only, reuse the production payload builders and validation rules and never
# read or write the workspace's real contacts or deals, so the Playground has an explicit adapter for every
# customer tool instead of a refusal.
module Captain::Playground::CustomerProfileTools
  CUSTOMER_PROFILE_ARGUMENTS = {
    'get_my_contact' => [].freeze,
    'update_my_contact' => %w[first_name last_name middle_name iin birth_date gender phone_number email].freeze,
    'list_my_deals' => %w[status pipeline limit offset].freeze
  }.freeze
  MY_DEAL_STATUSES = %w[open won lost any].freeze
  MY_DEAL_TERMINAL_OUTCOMES = %w[won lost].freeze

  private

  def my_contact_details
    customer_profile_arguments!
    { success: true, contact: my_contact_payload, simulated: true }
  end

  def my_contact_payload
    Captain::Tools::Account::GetMyContactService.payload(contact_projection(caller)).deep_dup
  end

  def update_my_contact
    customer_profile_arguments!
    commit_my_contact!(my_contact_candidate(my_contact_changes))
    { success: true, contact: my_contact_payload, simulated: true }
  rescue Captain::Tools::Account::UpdateMyContactService::InvalidBirthDate
    { success: false, reason: 'validation_error', field: 'birth_date', simulated: true }
  rescue ArgumentError
    { success: false, reason: 'validation_error', simulated: true }
  end

  # Same field mapping and value rules as the production service, applied to the scenario caller.
  def my_contact_changes
    rules = Captain::Tools::Account::UpdateMyContactService.allocate
    attributes = @args.slice('first_name', 'last_name', 'middle_name', 'iin', 'phone_number', 'email').symbolize_keys
                      .transform_values { |value| value.is_a?(String) ? value.strip.presence : value }
    attributes[:name] = attributes.delete(:first_name) if attributes.key?(:first_name)
    attributes[:identifier] = rules.send(:validated_iin, attributes.delete(:iin)) if attributes.key?(:iin)
    raise ArgumentError, 'Phone is reserved' if attributes[:phone_number].present? && synthetic_reserved_phone?(attributes[:phone_number])

    custom = {}
    custom['birth_date'] = rules.send(:validated_birth_date, @args['birth_date']) if @args.key?('birth_date')
    custom['gender'] = rules.send(:validated_gender, @args['gender']) if @args.key?('gender')
    custom['iin'] = attributes[:identifier] if attributes.key?(:identifier)
    attributes[:custom_attributes] = CustomAttributes::MutationService.merge(caller['custom_attributes'], custom) if custom.present?
    attributes
  end

  def my_contact_candidate(changes)
    candidate = contact_projection(caller.merge(changes.stringify_keys))
    candidate.send(:prepare_contact_attributes)
    candidate.send(:normalize_phone_number)
    candidate.send(:sync_contact_attributes)
    raise ArgumentError, 'Contact name is required' if candidate.name.blank?

    validate_contact_company_projection!(candidate, %i[email phone_number identifier])
    validate_synthetic_contact_uniqueness!(candidate)
    candidate
  end

  # Nothing is written before every rule passed, so a rejected update leaves the scenario untouched.
  def commit_my_contact!(candidate)
    fields = Captain::Playground::ContactCompanyTools::CONTACT_PROJECTION_FIELDS
    attributes = candidate.attributes.slice(*fields).deep_stringify_keys
    current = contact_projection(caller).attributes.slice(*fields).deep_stringify_keys
    changed = attributes.except('created_at', 'updated_at') != current.except('created_at', 'updated_at')
    attributes['updated_at'] = Time.current.iso8601 if changed
    caller.merge!(attributes)
  end

  def list_my_deals
    customer_profile_arguments!
    status = @args['status'].to_s.presence || 'any'
    raise ArgumentError, 'Invalid status' unless MY_DEAL_STATUSES.include?(status)

    rules = Captain::Tools::Account::ListMyDealsService.allocate
    limit = rules.send(:validated_limit, @args['limit'])
    offset = rules.send(:parse_offset, @args['offset'])
    deals = my_deals_in_scope(status, @args['pipeline'])
    page = deals.sort_by { |record| my_deal_sort_key(record) }.drop(offset).first(limit)
    { success: true, total: deals.size, limit: limit, offset: offset, has_more: offset + limit < deals.size,
      deals: page.map { |record| my_deal_card(record) }, simulated: true }
  rescue ArgumentError
    { success: false, reason: 'validation_error', simulated: true }
  end

  def customer_profile_arguments!
    unknown = @args.keys - CUSTOMER_PROFILE_ARGUMENTS.fetch(@tool_id)
    raise ArgumentError, "Unsupported #{@tool_id} arguments: #{unknown.join(', ')}" if unknown.any?
  end

  def my_deals_in_scope(status, pipeline)
    deals = @data['deals'].select { |record| record['contact_id'] == caller['id'] }
    deals = deals.select { |record| my_deal_open?(record) } if status == 'open'
    deals = deals.select { |record| my_deal_outcome(record) == status } if MY_DEAL_TERMINAL_OUTCOMES.include?(status)
    my_deals_in_pipeline(deals, pipeline)
  end

  def my_deals_in_pipeline(deals, selector)
    selector = selector.to_s.strip
    return deals if selector.blank?

    pipeline_ids = @data['pipelines'].select { |pipeline| my_pipeline_matches?(pipeline, selector) }.pluck('id')
    deals.select { |record| pipeline_ids.include?(record['pipeline_id']) }
  end

  def my_pipeline_matches?(pipeline, selector)
    if selector.match?(/\A-?[1-9]\d*\z/)
      return pipeline['id'] == @session.namespace.decode({ 'pipeline_id' => selector.to_i }).fetch('pipeline_id')
    end

    [pipeline['name'], pipeline['code']].any? { |value| value.to_s.downcase == selector.downcase }
  end

  def my_deal_outcome(record)
    stage = @data['stages'].find { |item| item['id'] == record['stage_id'] }
    outcome = (stage && (stage['outcome'] || stage['stage_type'])).to_s
    MY_DEAL_TERMINAL_OUTCOMES.include?(outcome) ? outcome : 'open'
  end

  def my_deal_open?(record)
    record['archived_at'].blank? && record['closed_at'].blank? && my_deal_outcome(record) == 'open'
  end

  def my_deal_status(record)
    outcome = my_deal_outcome(record)
    return outcome if MY_DEAL_TERMINAL_OUTCOMES.include?(outcome)
    return 'archived' if record['archived_at'].present?

    record['closed_at'].present? ? 'closed' : 'open'
  end

  # Newest first, like the production page order (updated_at DESC, id DESC).
  def my_deal_sort_key(record)
    [-Time.iso8601(record['updated_at'] || record['created_at'] || '1970-01-01T00:00:00Z').to_f, -record['id'].to_i]
  end

  def my_deal_card(record)
    pipeline = @data['pipelines'].find { |item| item['id'] == record['pipeline_id'] }
    stage = @data['stages'].find { |item| item['id'] == record['stage_id'] }
    stamp = record['updated_at'] || record['created_at']
    zone = Time.find_zone(@data['timezone']) || Time.zone
    { id: record['id'], title: record['title'], pipeline: pipeline&.fetch('name', nil) || record['pipeline_name'],
      stage: stage&.fetch('name', nil) || record['stage_name'], status: my_deal_status(record), amount: record['amount'],
      currency: record['currency'], updated_at: stamp && Time.iso8601(stamp.to_s).in_time_zone(zone).iso8601 }
  end
end
