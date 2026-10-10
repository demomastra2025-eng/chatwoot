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

  def deal_stages
    pipeline_id = @args['pipeline_id'] || (@args['deal_id'] && deal!(@args['deal_id'])['pipeline_id']) || @data['pipelines'].first['id']
    record!('pipelines', pipeline_id)
    { stages: @data['stages'].select { |stage| stage['pipeline_id'].to_s == pipeline_id.to_s }.deep_dup, simulated: true }
  end

  def selected_pipeline_and_stage(record = nil)
    pipeline = if @args['pipeline_id']
                 record!('pipelines', @args['pipeline_id'])
               elsif @args['pipeline_code']
                 @data['pipelines'].find { |item| item['code'] == @args['pipeline_code'] }
               else
                 record ? record!('pipelines', record['pipeline_id']) : @data['pipelines'].first
               end
    raise ArgumentError, 'Pipeline is not available' unless pipeline

    stages = @data['stages'].select { |stage| stage['pipeline_id'] == pipeline['id'] }
    stage = if @args['stage_id']
              stages.find { |item| item['id'].to_s == @args['stage_id'].to_s }
            elsif @args['stage_name'] || @args['stage_code']
              stages.find { |item| item['name'] == @args['stage_name'] || item['code'] == @args['stage_code'] }
            else
              stages.find { |item| item['id'] == record&.fetch('stage_id', nil) } || stages.first
            end
    raise ArgumentError, 'Stage is not available for this pipeline' unless stage

    [pipeline, stage]
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
    record.merge!(deal_attributes(record))
    deal_payload(record, action: @tool_id)
  end

  def create_task
    raise ArgumentError, 'Task title is required' if @args['title'].blank?
    deal = deal!(@args['deal_id']) if @args['deal_id']
    parse_time(@args['due_at']) if @args['due_at']
    record = @args.slice('title', 'description', 'due_at', 'priority', 'activity_type').merge(
      'id' => @scenario.next_id!, 'contact_id' => caller['id'], 'deal_id' => deal&.fetch('id', nil), 'status_id' => 1, 'status_name' => 'Открыта',
      'originating_conversation_id' => @data['conversation']['id'], 'custom_attributes' => json_object(@args['custom_attributes'])
    )
    @data['tasks'] << record
    { action: 'create_task', task: record.deep_dup, task_id: record['id'], simulated: true }
  end

  def update_task
    record = record!('tasks', @args.fetch('task_id'))
    raise ArgumentError, 'Record is not available' unless record['contact_id'] == caller['id']
    parse_time(@args['due_at']) if @args['due_at']
    record.merge!(@args.slice('title', 'description', 'due_at', 'priority', 'status_id', 'status_name', 'outcome'))
    { action: @tool_id, task: record.deep_dup, simulated: true }
  end
end
