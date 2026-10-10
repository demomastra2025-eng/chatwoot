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
    %w[pipeline_id stage_id].each do |key|
      records = records.select { |deal| deal[key].to_s == @args[key].to_s } if @args[key]
    end
    { deals: records.map { |record| deal_payload(record)[:deal] }, total_count: records.size, simulated: true }
  end

  def deal_attributes(record = nil)
    attrs = @args.slice(*Captain::Playground::Scenario::DEAL_FIELDS).except('custom_attributes')
    raise ArgumentError, 'Deal title is required' if attrs.key?('title') && attrs['title'].blank?
    if attrs.key?('amount')
      decimal = BigDecimal(attrs['amount'].to_s)
      raise ArgumentError, 'Deal amount must be a nonnegative whole number in major currency units' unless decimal.finite? && decimal >= 0 && decimal.frac.zero?

      attrs['amount'] = decimal.to_i
    end
    if attrs['win_probability'] && !Float(attrs['win_probability']).between?(0, 100)
      raise ArgumentError, 'Win probability must be between 0 and 100'
    end
    Date.iso8601(attrs['expected_close_on']) if attrs['expected_close_on']
    raise ArgumentError, 'Currency must be a three letter code' if attrs['currency'] && !attrs['currency'].match?(/\A[A-Z]{3}\z/)

    pipeline, stage = selected_pipeline_and_stage(record)
    attrs.merge!('pipeline_id' => pipeline['id'], 'pipeline_name' => pipeline['name'], 'stage_id' => stage['id'], 'stage_name' => stage['name'])
    attrs['custom_attributes'] = record.to_h.fetch('custom_attributes', {}).merge(json_object(@args['custom_attributes'])) if @args['custom_attributes']
    attrs
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

  def get_deal
    { deal: deal!(@args.fetch('deal_id')).deep_dup, simulated: true }
  end
end
