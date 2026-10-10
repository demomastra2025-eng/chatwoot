module Captain::Playground::DealStageTools
  private

  def deal_pipelines
    records = @data['pipelines'].map { |pipeline| pipeline.merge('stages' => @data['stages'].select { |stage| stage['pipeline_id'] == pipeline['id'] }) }
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

    stages = @data['stages'].select { |stage| stage['pipeline_id'] == pipeline['id'] }
    stage = selected_stage(stages, record)
    raise ArgumentError, 'Stage is not available for this pipeline' unless stage
    if @args['closing_reasons'].present? || @args['transition_reason'].present?
      raise ArgumentError, 'No transition reasons are configured in this Trial pipeline'
    end

    [pipeline, stage]
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
    raise ArgumentError, 'Stage action cannot be combined with an exact stage' if %w[stage_id stage_name stage_code].any? { |field| @args[field].present? }

    index = stages.index { |stage| stage['id'] == record&.fetch('stage_id', nil) }
    raise ArgumentError, 'Current deal stage is unavailable in this pipeline' unless index

    target = index + (action == 'next' ? 1 : -1)
    target.between?(0, stages.size - 1) ? stages[target] : nil
  end
end
