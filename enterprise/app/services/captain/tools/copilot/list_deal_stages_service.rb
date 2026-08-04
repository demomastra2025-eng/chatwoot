class Captain::Tools::Copilot::ListDealStagesService < Captain::Tools::Copilot::BaseAccountTool
  def self.name
    'list_deal_stages'
  end

  description 'List ordered CRM deal stages for one pipeline or deal. Prefer pipeline_name for a user-provided name and never guess numeric IDs.'
  param :pipeline_id, type: :number, desc: 'Verified pipeline ID returned by a prior tool. Never guess or default this ID.', required: false
  param :pipeline_code, type: :string, desc: 'Verified pipeline code to list stages for', required: false
  param :pipeline_name, type: :string, desc: 'Exact user-provided pipeline name, for example Продажи. Prefer it over guessing an ID.', required: false
  param :deal_id, type: :number, desc: 'Verified deal ID for pipeline/current stage lookup. Omit it when asking about a pipeline.', required: false
  param :current_deal, type: :boolean, desc: 'Use the deal linked to the current conversation', required: false
  param :include_inactive, type: :boolean, desc: 'Include inactive stages; default false', required: false

  def execute(**arguments)
    context = stage_context(arguments)
    formatted_payload(stage_list_payload(arguments, context))
  rescue StandardError => e
    tool_failure(e)
  end

  def active?
    feature_enabled?('crm_deals') && (user_has_permission('crm_deal_view') || user_has_permission('crm_deal_manage'))
  end

  private

  def stage_context(arguments)
    include_inactive = cast_boolean(arguments[:include_inactive])
    selector = pipeline_selector(arguments)
    effective_deal_id = arguments[:deal_id] if selector.blank?
    effective_current_deal = cast_boolean(arguments[:current_deal]) && selector.blank?
    deal = resolve_deal(deal_id: effective_deal_id, use_current_deal: effective_current_deal)
    pipeline = resolve_pipeline(selector: selector, deal: deal)
    stages = pipeline.stages.ordered
    stages = stages.active unless include_inactive

    {
      selector: selector,
      effective_deal_id: effective_deal_id,
      effective_current_deal: effective_current_deal,
      deal: deal,
      pipeline: pipeline,
      stages: stages,
      include_inactive: include_inactive
    }
  end

  def stage_list_payload(arguments, context)
    pipeline = context[:pipeline]
    deal = context[:deal]
    stages = context[:stages]
    default_stage = default_stage_for(pipeline)
    stage_payloads = stages.map { |stage| stage_payload(stage, default_stage_id: default_stage&.id) }
    current_stage = deal&.stage if deal&.pipeline_id == pipeline.id
    previous_stage, next_stage = neighbor_stages(stages.to_a, current_stage)

    {
      action: 'list_deal_stages',
      filters: stage_filters(context),
      ignored_filters: ignored_filters(arguments, context[:selector]),
      pipeline: ::Crm::PayloadBuilder.pipeline(pipeline, include_stages: false).except(:deal_count),
      current_deal: current_deal_payload(deal),
      current_stage: stage_payload(current_stage),
      previous_stage: stage_payload(previous_stage),
      next_stage: stage_payload(next_stage),
      returned_count: stage_payloads.length,
      stages: stage_payloads
    }
  end

  def stage_filters(context)
    selected_pipeline_filter(context[:selector]).merge(
      deal_id: context[:effective_deal_id],
      current_deal: context[:effective_current_deal],
      include_inactive: context[:include_inactive]
    ).compact
  end

  def ignored_filters(arguments, selector)
    return {} if selector.blank?

    selected_key = :"pipeline_#{selector[:type]}"
    arguments.slice(:pipeline_id, :pipeline_code, :pipeline_name, :deal_id, :current_deal)
             .compact
             .except(selected_key)
  end

  def selected_pipeline_filter(selector)
    return {} if selector.blank?

    { :"pipeline_#{selector[:type]}" => selector[:value] }
  end

  def resolve_deal(deal_id:, use_current_deal:)
    return account.crm_deals.includes(:pipeline, :stage).find(deal_id) if deal_id.present?
    return current_deal if use_current_deal

    nil
  end

  def pipeline_selector(arguments)
    return { type: :name, value: arguments[:pipeline_name] } if arguments[:pipeline_name].present?
    return { type: :code, value: arguments[:pipeline_code] } if arguments[:pipeline_code].present?
    return { type: :id, value: arguments[:pipeline_id] } if arguments[:pipeline_id].present?

    nil
  end

  def resolve_pipeline(selector:, deal:)
    return deal.pipeline if selector.blank? && deal.present?
    return default_pipeline if selector.blank?

    scope = account.crm_pipelines.active
    return scope.find(selector[:value]) if selector[:type] == :id
    return scope.find_by!(code: normalized_code(selector[:value])) if selector[:type] == :code

    scope.find_by!('LOWER(name) = ?', selector[:value].to_s.strip.downcase)
  end

  def default_pipeline
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

  def stage_payload(stage, default_stage_id: nil)
    return if stage.blank?

    payload = ::Crm::PayloadBuilder.stage(stage)
    payload[:default] = stage.id == default_stage_id unless default_stage_id.nil?
    payload
  end

  def default_stage_for(pipeline)
    pipeline.stages.active.where(outcome: 'open').ordered.first || pipeline.stages.active.ordered.first
  end

  def normalized_code(value)
    ::Crm::CodeNormalizer.normalize(value)
  end
end
