module Captain::Playground::DealStageTools
  private

  def deal_pipelines
    records = @data['pipelines'].map do |pipeline|
      pipeline.merge('stages' => @data['stages'].select do |stage|
        stage['pipeline_id'] == pipeline['id']
      end)
    end
    { pipelines: records, simulated: true }
  end

  def deal_stages
    pipeline_id = @args['pipeline_id'] || (@args['deal_id'] && deal!(@args['deal_id'])['pipeline_id']) || @data['pipelines'].first['id']
    record!('pipelines', pipeline_id)
    { stages: @data['stages'].select { |stage| stage['pipeline_id'].to_s == pipeline_id.to_s }.deep_dup, simulated: true }
  end

  def selected_pipeline(record)
    return record!('pipelines', @args['pipeline_id']) if @args['pipeline_id']
    if @args['pipeline_code']
      return @data['pipelines'].find { |item| item['code'] == @args['pipeline_code'] } || raise(ArgumentError, 'Pipeline is not available')
    end

    record ? record!('pipelines', record['pipeline_id']) : @data['pipelines'].first
  end

  def selected_pipeline_and_stage(record = nil)
    pipeline = selected_pipeline(record)
    raise ArgumentError, 'Pipeline is not available' unless pipeline

    stages = @data['stages'].select { |stage| stage['pipeline_id'] == pipeline['id'] && stage['active'] != false }
    stage = selected_stage(stages, record)
    raise ArgumentError, 'Stage is not available for this pipeline' unless stage
    [pipeline, stage]
  end

  def validated_stage_attributes(pipeline, stage, attributes, record)
    pipeline_projection = native_snapshot(Crm::Pipeline, pipeline)
    stages = @data['stages'].select { |item| item['pipeline_id'] == pipeline['id'] }.map do |item|
      projection = native_snapshot(Crm::Stage, item.merge('outcome' => item['outcome'] || item['stage_type'] || 'open'))
      load_snapshot_association(projection, :pipeline, pipeline_projection)
      projection
    end
    scope = Captain::Playground::RecordSnapshots::SnapshotScope.new(stages)
    pipeline_projection.define_singleton_method(:stages) { scope }
    target_stage = stages.find { |item| item.id == stage['id'] }
    deal = native_snapshot(Crm::Deal, record.to_h.merge(attributes).merge('stage_id' => record.to_h['stage_id'], 'primary_contact_id' => caller['id']))
    service = Crm::Deals::TransitionService.new(account: @session.account, deal: deal, params: @args, actor: @session.user)
    changing = record.to_h['stage_id'] != stage['id']
    closing_reasons = service.send(:resolve_closing_reasons!, target_stage: target_stage,
      current_reasons: record.to_h.fetch('closing_reasons', []), require_input: changing)
    transition_reason = service.send(:resolve_transition_reason!, target_stage: target_stage, require_input: changing)
    if changing
      requirements = Array(stage['field_requirements']).map do |item|
        definition = @data['custom_fields'].find { |field| field['entity_kind'] == 'deal' && field['key'] == item['field_key'] }
        projection = Crm::StageFieldRequirement.new(item.slice('field_key', 'required', 'validation', 'role_exemptions'))
        load_snapshot_association(projection, :field_definition, definition && Crm::FieldDefinition.new(definition.except('id')))
        projection
      end
      inspector = Crm::RequiredFieldsInspector.new(account: @session.account, entity_kind: :deal, record: deal,
        custom_attributes: deal.custom_attributes, context: 'deal_stage_transition', actor: @session.user, requirements: requirements)
      inspector.instance_variable_set(:@catalog, field_catalog('deal', context: 'deal_stage_transition'))
      policy = Crm::Deals::StageEntryPolicy.new(deal: deal, target_stage: target_stage, account: @session.account, actor: @session.user)
      policy.define_singleton_method(:required_field_issues) { inspector.missing_field_details }
      policy.enforce!
    end
    { 'closing_reasons' => closing_reasons, 'transition_reason' => transition_reason,
      'closed_at' => target_stage.terminal_outcome? ? record.to_h['closed_at'] || Time.current.iso8601 : nil }
  end

  def selected_stage(stages, record)
    return relative_stage(stages, record) if @args['stage_action'].present?
    return stages.find { |item| item['id'].to_s == @args['stage_id'].to_s } if @args['stage_id']
    if @args['stage_name'] || @args['stage_code']
      return stages.find { |item| item['name'].casecmp?(@args['stage_name'].to_s) || item['code'] == @args['stage_code'] }
    end

    stages.find { |item| item['id'] == record&.fetch('stage_id', nil) } || stages.first
  end

  def relative_stage(stages, record)
    action = @args['stage_action']
    raise ArgumentError, 'Stage action must be next or previous' unless %w[next previous].include?(action)
    raise ArgumentError, 'Stage action cannot be combined with an exact stage' if %w[stage_id stage_name stage_code].any? do |field|
      @args[field].present?
    end

    index = stages.index { |stage| stage['id'] == record&.fetch('stage_id', nil) }
    raise ArgumentError, 'Current deal stage is unavailable in this pipeline' unless index

    target = index + (action == 'next' ? 1 : -1)
    target.between?(0, stages.size - 1) ? stages[target] : nil
  end
end
