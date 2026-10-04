module Api::V1::Accounts::Crm::Concerns::StageParameterSupport
  FIELD_REQUIREMENT_PARAMS = [:field_key, :required, { validation: {}, role_exemptions: [] }].freeze
  MOVABLE_STAGE_PARAMS = [
    :id,
    :name,
    :color,
    :active,
    :default,
    :transition_reason_required,
    { transition_reason_options: [], field_requirements: FIELD_REQUIREMENT_PARAMS }
  ].freeze
  TERMINAL_STAGE_PARAMS = [
    :id,
    :name,
    :closing_reason_required,
    { closing_reason_options: [], field_requirements: FIELD_REQUIREMENT_PARAMS }
  ].freeze

  private

  def create_stage_params
    attributes = stage_params.except(:outcome).merge(outcome: 'open')
    attributes[:position] = params.permit(:position)[:position] if params.key?(:position)
    attributes
  end

  def update_stage_params
    return terminal_stage_params if @stage.terminal_outcome?
    return technical_stage_params if @stage.technical_stage?

    stage_params.except(:outcome, :closing_reason_required, :closing_reason_options)
  end

  def stage_params
    params.permit(
      :name,
      :code,
      :outcome,
      :active,
      :color,
      :default,
      :closing_reason_required,
      :transition_reason_required,
      closing_reason_options: [],
      transition_reason_options: []
    )
  end

  def batch_update_params
    params.permit(
      deleted_stage_ids: [],
      stages: MOVABLE_STAGE_PARAMS,
      technical_stage: [:id, :active],
      terminal_stages: TERMINAL_STAGE_PARAMS,
      pipeline_rules: [:restrict_stage_skipping, :restrict_backward_move, :allow_stage_rule_override]
    )
  end

  def terminal_stage_params
    params.permit(:name, :closing_reason_required, closing_reason_options: [])
  end

  def technical_stage_params
    params.permit(:active, :color)
  end
end
