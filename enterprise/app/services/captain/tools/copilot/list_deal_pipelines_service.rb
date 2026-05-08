class Captain::Tools::Copilot::ListDealPipelinesService < Captain::Tools::Copilot::BaseAccountTool
  def self.name
    'list_deal_pipelines'
  end

  description 'List active CRM deal pipelines with ordered stages. Use this before creating or moving deals; prefer stage_id for transitions.'
  param :include_inactive, type: :boolean, desc: 'Include inactive pipelines and stages; default false', required: false

  def execute(include_inactive: nil)
    include_inactive_records = cast_boolean(include_inactive)
    pipelines = account.crm_pipelines.includes(:stages).ordered
    pipelines = pipelines.active unless include_inactive_records

    records = pipelines.map { |pipeline| pipeline_payload(pipeline, include_inactive: include_inactive_records) }

    formatted_payload(
      action: 'list_deal_pipelines',
      filters: { include_inactive: include_inactive_records },
      returned_count: records.length,
      pipelines: records
    )
  rescue StandardError => e
    tool_failure(e)
  end

  def active?
    feature_enabled?('crm_deals') && (user_has_permission('crm_deal_view') || user_has_permission('crm_deal_manage'))
  end

  private

  def pipeline_payload(pipeline, include_inactive:)
    stages = pipeline.stages.ordered
    stages = stages.active unless include_inactive
    default_stage = default_stage_for(pipeline)

    ::Crm::PayloadBuilder.pipeline(pipeline, include_stages: false).except(:deal_count).merge(
      stages: stages.map do |stage|
        stage_payload(stage, default_stage_id: default_stage&.id)
      end
    )
  end

  def default_stage_for(pipeline)
    pipeline.stages.active.where(outcome: 'open').ordered.first || pipeline.stages.active.ordered.first
  end

  def stage_payload(stage, default_stage_id:)
    ::Crm::PayloadBuilder.stage(stage).merge(
      default: stage.id == default_stage_id
    )
  end
end
