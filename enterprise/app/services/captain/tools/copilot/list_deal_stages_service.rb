class Captain::Tools::Copilot::ListDealStagesService < Captain::Tools::Copilot::BaseAccountTool
  def self.name
    'list_deal_stages'
  end

  description 'List ordered CRM deal stages for a pipeline or current deal, including previous/next stage by position.'
  param :pipeline_id, type: :number, desc: 'Pipeline ID to list stages for', required: false
  param :pipeline_code, type: :string, desc: 'Pipeline code to list stages for', required: false
  param :deal_id, type: :number, desc: 'Deal ID whose pipeline/current stage should be used', required: false
  param :current_deal, type: :boolean, desc: 'Use the deal linked to the current conversation', required: false
  param :include_inactive, type: :boolean, desc: 'Include inactive stages; default false', required: false

  def execute(pipeline_id: nil, pipeline_code: nil, deal_id: nil, current_deal: nil, include_inactive: nil)
    include_inactive_records = cast_boolean(include_inactive)
    deal = resolve_deal(deal_id: deal_id, use_current_deal: cast_boolean(current_deal))
    pipeline = resolve_pipeline(pipeline_id: pipeline_id, pipeline_code: pipeline_code, deal: deal)
    stages = pipeline.stages.ordered
    stages = stages.active unless include_inactive_records
    stage_deal_counts = account.crm_deals.group(:stage_id).count
    default_stage = default_stage_for(pipeline)
    stage_payloads = stages.map do |stage|
      stage_payload(
        stage,
        default_stage_id: default_stage&.id,
        deal_count: stage_deal_counts[stage.id].to_i
      )
    end
    current_stage = deal&.stage if deal&.pipeline_id == pipeline.id
    previous_stage, next_stage = neighbor_stages(stages.to_a, current_stage)

    formatted_payload(
      action: 'list_deal_stages',
      filters: {
        pipeline_id: pipeline_id,
        pipeline_code: pipeline_code,
        deal_id: deal_id,
        current_deal: cast_boolean(current_deal),
        include_inactive: include_inactive_records
      }.compact,
      pipeline: ::Crm::PayloadBuilder.pipeline(pipeline, include_stages: false),
      current_deal: current_deal_payload(deal),
      current_stage: stage_payload(current_stage),
      previous_stage: stage_payload(previous_stage),
      next_stage: stage_payload(next_stage),
      total_count: stage_payloads.length,
      stages: stage_payloads
    )
  rescue StandardError => e
    tool_failure(e)
  end

  def active?
    feature_enabled?('crm_deals') && (user_has_permission('crm_deal_view') || user_has_permission('crm_deal_manage'))
  end

  private

  def resolve_deal(deal_id:, use_current_deal:)
    return account.crm_deals.includes(:pipeline, :stage).find(deal_id) if deal_id.present?
    return current_deal if use_current_deal

    nil
  end

  def resolve_pipeline(pipeline_id:, pipeline_code:, deal:)
    return account.crm_pipelines.active.find(pipeline_id) if pipeline_id.present?
    return account.crm_pipelines.active.find_by!(code: normalized_code(pipeline_code)) if pipeline_code.present?
    return deal.pipeline if deal.present?

    account.crm_pipelines.active.find_by(default: true) || account.crm_pipelines.active.ordered.first ||
      raise(ArgumentError, 'No active CRM deal pipeline is available')
  end

  def neighbor_stages(stages, current_stage)
    return [nil, nil] if current_stage.blank?

    current_index = stages.index { |stage| stage.id == current_stage.id }
    return [nil, nil] if current_index.blank?

    previous_stage = current_index.positive? ? stages[current_index - 1] : nil
    next_stage = stages[current_index + 1]

    [previous_stage, next_stage]
  end

  def current_deal_payload(deal)
    return if deal.blank?

    {
      id: deal.id,
      pipeline_id: deal.pipeline_id,
      stage_id: deal.stage_id,
      title: deal.title
    }
  end

  def stage_payload(stage, default_stage_id: nil, deal_count: nil)
    return if stage.blank?

    payload = ::Crm::PayloadBuilder.stage(stage)
    payload[:default] = stage.id == default_stage_id unless default_stage_id.nil?
    payload[:deal_count] = deal_count unless deal_count.nil?
    payload
  end

  def default_stage_for(pipeline)
    pipeline.stages.active.where(outcome: 'open').ordered.first || pipeline.stages.active.ordered.first
  end

  def normalized_code(value)
    ::Crm::CodeNormalizer.normalize(value)
  end
end
