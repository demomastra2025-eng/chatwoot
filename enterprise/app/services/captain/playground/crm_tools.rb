module Captain::Playground::CrmTools
  private

  def deal!(id = nil)
    id ||= @context.state.dig(:deal, :id)
    record = record!('deals', id)
    raise ArgumentError, 'Record is not available' unless record['contact_id'] == caller['id']

    record
  end

  def deal_payload(record, action: nil)
    { action: action, deal_id: record['id'], pipeline_id: record['pipeline_id'], stage_id: record['stage_id'], title: record['title'],
      amount: record['amount'], currency: record['currency'], deal: record.deep_dup, simulated: true }.compact
  end

  def search_deals
    require_caller_filter!
    records = @data['deals'].select { |deal| deal['contact_id'] == caller['id'] }
    query = @args['query'].presence || @args['title'].presence
    records = records.select { |deal| deal['title'].downcase.include?(query.downcase) } if query
    records = filter_deal_fields(records)
    records = filter_deal_status(records)
    total = records.size
    limit = @args['limit'].to_i
    limit = limit.positive? ? [limit, 50].min : 50
    offset = deal_search_offset
    records = records.sort_by do |record|
      [-Time.iso8601(record['updated_at'] || record['created_at'] || '1970-01-01T00:00:00Z').to_f, -record['id'].to_i]
    end.drop(offset).first(limit)
    has_more = offset + records.size < total
    {
      deals: records.map { |record| deal_payload(record)[:deal] }, total_count: total, shown: records.size,
      limit: limit, offset: offset, has_more: has_more, next_offset: has_more ? offset + records.size : nil,
      sort: ['updated_at DESC', 'id DESC'], simulated: true
    }
  end

  def filter_deal_status(records)
    status = @args['status'].presence
    unless status
      archived = !!ActiveModel::Type::Boolean.new.cast(@args['archived'])
      return records.select { |record| record['archived_at'].present? == archived }
    end
    raise ArgumentError, 'status must be active, closed, archived, or any' unless %w[active closed archived any].include?(status)

    records.select do |record|
      stage = @data['stages'].find { |item| item['id'] == record['stage_id'] }
      active = record['archived_at'].blank? && record['closed_at'].blank? && stage&.fetch('outcome', 'open') == 'open'
      case status
      when 'active' then active
      when 'closed' then !active && record['archived_at'].blank?
      when 'archived' then record['archived_at'].present?
      when 'any' then true
      else raise ArgumentError, 'status must be active, closed, archived, or any'
      end
    end
  end

  def deal_search_offset
    value = @args['offset']
    return 0 if value.nil? || value.to_s.strip.empty?
    raise ArgumentError, 'offset must be a non-negative integer of at most 9 digits' unless value.to_s.match?(/\A\d{1,9}\z/)

    value.to_i
  end

  def filter_deal_fields(records)
    %w[pipeline_id stage_id].each do |key|
      records = records.select { |deal| deal[key].to_s == @args[key].to_s } if @args[key]
    end
    records
  end

  def deal_attributes(record = nil)
    attrs = @args.slice(*Captain::Playground::Scenario::DEAL_FIELDS).except('custom_attributes')
    validate_deal_strings!(attrs)
    validate_deal_timeline!(attrs)
    attrs['amount'] = deal_amount(attrs['amount']) if attrs.key?('amount')
    pipeline, stage = selected_pipeline_and_stage(record)
    attrs.merge!('pipeline_id' => pipeline['id'], 'pipeline_name' => pipeline['name'], 'stage_id' => stage['id'], 'stage_name' => stage['name'])
    if @args['custom_attributes']
      attrs['custom_attributes'] = record.to_h.fetch('custom_attributes', {}).merge(json_object(@args['custom_attributes']))
    end
    attrs
  end

  def deal_amount(value)
    decimal = BigDecimal(value.to_s)
    unless decimal.finite? && decimal >= 0 && decimal.frac.zero?
      raise ArgumentError, 'Deal amount must be a nonnegative whole number in major currency units'
    end

    decimal.to_i
  end

  def validate_deal_timeline!(attrs)
    raise ArgumentError, 'Win probability must be between 0 and 100' if attrs['win_probability'] && !Float(attrs['win_probability']).between?(0, 100)

    Date.iso8601(attrs['expected_close_on']) if attrs['expected_close_on']
  end

  def validate_deal_strings!(attrs)
    raise ArgumentError, 'Deal title is required' if attrs.key?('title') && attrs['title'].blank?

    raise ArgumentError, 'Currency must be a three letter code' if attrs['currency'] && !attrs['currency'].match?(/\A[A-Z]{3}\z/)
  end

  def create_deal
    raise ArgumentError, 'Deal title is required' if @args['title'].blank?

    record = { 'id' => @scenario.next_id!, 'contact_id' => caller['id'], 'currency' => 'KZT', 'amount' => 0,
               'originating_conversation_id' => @data['conversation']['id'], 'custom_attributes' => {} }.merge(deal_attributes)
    @data['deals'] << record
    deal_payload(record, action: 'create_deal')
  end

  def update_deal
    record = deal!(@args['deal_id'])
    previous = record!('stages', record['stage_id']).deep_dup
    record.merge!(deal_attributes(record))
    result = deal_payload(record, action: @tool_id)
    return result unless @tool_id == 'transition_deal_stage'

    result.merge(previous_stage: previous, current_stage: record!('stages', record['stage_id']).deep_dup)
  end

  def deal_details
    { deal: deal!(@args.fetch('deal_id')).deep_dup, simulated: true }
  end
end
