class Crm::Pipelines::DefaultStageBuilder
  DEFAULT_STAGE_DEFINITIONS = [
    { code: 'new', name: 'New', outcome: 'open' },
    { code: 'qualified', name: 'Qualified', outcome: 'open' },
    { code: 'proposal', name: 'Proposal', outcome: 'open' },
    { code: 'won', name: 'Won', outcome: 'won', color: ::Crm::Stage::WON_COLOR },
    { code: 'lost', name: 'Lost', outcome: 'lost', color: ::Crm::Stage::LOST_COLOR }
  ].freeze
  TERMINAL_STAGE_DEFINITIONS = DEFAULT_STAGE_DEFINITIONS.select do |definition|
    definition[:outcome].in?(::Crm::Stage::TERMINAL_OUTCOMES)
  end.freeze

  attr_reader :pipeline

  def initialize(pipeline:)
    @pipeline = pipeline
  end

  def perform
    return pipeline unless pipeline&.persisted?

    if stages_scope.exists?
      ensure_terminal_stages
    else
      create_default_stages
    end

    pipeline.reload
  end

  private

  def create_default_stages
    DEFAULT_STAGE_DEFINITIONS.each_with_index do |definition, index|
      create_stage!(
        definition,
        color: color_for(definition, index),
        position: index + 1
      )
    end
  end

  def ensure_terminal_stages
    TERMINAL_STAGE_DEFINITIONS.each do |definition|
      ensure_terminal_stage(definition)
    end
  end

  def ensure_terminal_stage(definition)
    stage = stages_scope.find_by(outcome: definition[:outcome])
    return create_stage!(definition, color: definition[:color], position: next_position) if stage.blank?

    normalized_color = definition[:color].upcase
    changes = {}
    changes[:active] = true unless stage.active?
    changes[:default] = false if stage.default?
    changes[:color] = normalized_color if stage.color != normalized_color
    stage.update!(changes) if changes.any?
  end

  def create_stage!(definition, color:, position:)
    pipeline.stages.create!(
      account: pipeline.account,
      name: definition[:name],
      code: available_code(definition[:code]),
      color: color,
      outcome: definition[:outcome],
      position: position,
      active: true
    )
  end

  def color_for(definition, index)
    definition[:color] || ::Crm::Stage::STANDARD_COLORS[index] || ::Crm::Stage::DEFAULT_COLOR
  end

  def available_code(code)
    normalized_code = ::Crm::CodeNormalizer.normalize(code)
    return normalized_code unless stages_scope.exists?(code: normalized_code)

    suffix = 2
    loop do
      candidate = "#{normalized_code}_#{suffix}"
      return candidate unless stages_scope.exists?(code: candidate)

      suffix += 1
    end
  end

  def next_position
    stages_scope.maximum(:position).to_i + 1
  end

  def stages_scope
    ::Crm::Stage.where(pipeline_id: pipeline.id)
  end
end
