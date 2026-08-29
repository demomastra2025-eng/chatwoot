class Crm::Pipelines::DefaultStageBuilder
  DEFAULT_STAGE_DEFINITIONS = [
    { code: 'new', name: 'Unsorted', outcome: 'open', default: true },
    { code: 'qualified', name: 'Qualified', outcome: 'open' },
    { code: 'proposal', name: 'Proposal', outcome: 'open' },
    { code: 'won', name: 'Won', outcome: 'won', color: ::Crm::Stage::WON_COLOR },
    { code: 'lost', name: 'Lost', outcome: 'lost', color: ::Crm::Stage::LOST_COLOR }
  ].freeze
  SYSTEM_STAGE_DEFINITIONS = DEFAULT_STAGE_DEFINITIONS.select do |definition|
    definition[:code].in?(::Crm::Stage::TECHNICAL_STAGE_CODES) ||
      definition[:outcome].in?(::Crm::Stage::TERMINAL_OUTCOMES)
  end.freeze

  attr_reader :pipeline

  def initialize(pipeline:)
    @pipeline = pipeline
  end

  def perform
    return pipeline unless pipeline&.persisted?

    pipeline.with_lock do
      if stages_scope.exists?
        ensure_system_stages
      else
        create_default_stages
      end

      ensure_active_default_stage
      normalize_stage_positions
    end

    pipeline.reload
  end

  private

  def create_default_stages
    DEFAULT_STAGE_DEFINITIONS.each_with_index do |definition, index|
      create_stage!(
        definition,
        color: color_for(definition, index),
        position: index
      )
    end
  end

  def ensure_system_stages
    SYSTEM_STAGE_DEFINITIONS.each do |definition|
      ensure_system_stage(definition)
    end
  end

  def ensure_system_stage(definition)
    stage = find_system_stage(definition)
    return create_system_stage(definition) if stage.blank?

    changes = {}
    if definition[:code].in?(::Crm::Stage::TECHNICAL_STAGE_CODES)
      reconcile_technical_default(changes, stage)
      changes[:position] = 0 unless stage.position.zero?
    else
      changes[:active] = true unless stage.active?
      normalized_color = definition[:color].upcase
      changes[:default] = false if stage.default?
      changes[:color] = normalized_color if stage.color != normalized_color
    end
    stage.update!(changes) if changes.any?
  end

  def find_system_stage(definition)
    return stages_scope.find_by(code: definition[:code]) if definition[:code].in?(::Crm::Stage::TECHNICAL_STAGE_CODES)

    stages_scope.find_by(outcome: definition[:outcome])
  end

  def create_system_stage(definition)
    technical = definition[:code].in?(::Crm::Stage::TECHNICAL_STAGE_CODES)
    create_stage!(
      definition,
      color: definition[:color] || ::Crm::Stage::DEFAULT_COLOR,
      position: technical ? 0 : next_position
    )
  end

  def create_stage!(definition, color:, position:)
    pipeline.stages.create!(
      account: pipeline.account,
      name: definition[:name],
      code: available_code(definition[:code]),
      color: color,
      outcome: definition[:outcome],
      position: position,
      active: true,
      default: default_value_for(definition)
    )
  end

  def default_value_for(definition)
    return definition.fetch(:default, false) unless definition[:code].in?(::Crm::Stage::TECHNICAL_STAGE_CODES)

    active_default_stage.blank?
  end

  def active_default_stage
    stages_scope.active.find_by(default: true)
  end

  def reconcile_technical_default(changes, stage)
    unless stage.active?
      changes[:default] = false if stage.default?
      return
    end

    current_default = active_default_stage

    if current_default.present? && current_default.id != stage.id
      changes[:default] = false if stage.default?
    elsif !stage.default?
      changes[:default] = true
    end
  end

  def ensure_active_default_stage
    return if active_default_stage.present?

    stages_scope.active.where(outcome: 'open').ordered.first&.update!(default: true)
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

  def normalize_stage_positions
    stages_scope.ordered.each_with_index do |stage, index|
      stage.update!(position: index) unless stage.position == index
    end
  end

  def stages_scope
    ::Crm::Stage.where(pipeline_id: pipeline.id)
  end
end
