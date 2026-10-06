class Crm::Stages::BatchUpdateService
  def initialize(pipeline:, attributes:)
    @pipeline = pipeline
    @attributes = attributes.to_h.deep_symbolize_keys
  end

  def perform
    pipeline.with_lock do
      validate_movable_stage_draft!
      validate_default_selection!(stage_rows)
      validate_terminal_stage_draft!
      delete_stages!
      clear_existing_default! if stage_rows.any? { |row| boolean_value(row, :default, false) }
      ordered_stage_ids = upsert_movable_stages!
      update_technical_stage!
      update_terminal_stages!
      update_pipeline_rules!
      ensure_complete_stage_order!(ordered_stage_ids)
      persist_stage_order!(ordered_stage_ids)
      ensure_active_default_stage!
    end

    pipeline.reload
  end

  private

  attr_reader :pipeline, :attributes

  # The draft is applied all or nothing: every requested deletion is checked
  # before the first one runs, and a blocked stage rejects the whole batch
  # (422) so the other edits of the draft are never half-saved.
  def delete_stages!
    stages = deleted_stage_ids.map { |stage_id| pipeline.stages.lock.find(stage_id) }
    stages.each { |stage| ensure_deletable_stage!(stage) }
    stages.each(&:destroy!)
  end

  def ensure_deletable_stage!(stage)
    raise_stage_error!('STANDARD_STAGE_LOCKED', 'System stages cannot be deleted.', stage) if stage.system_stage?

    Crm::DealPresenceGuard.ensure_empty!(stage, note: 'Изменения не сохранены.')
  end

  def upsert_movable_stages!
    stage_rows.map { |row| upsert_movable_stage!(row) }
  end

  def upsert_movable_stage!(row)
    stage = find_or_build_movable_stage(row)
    raise_stage_error!('STANDARD_STAGE_LOCKED', 'System stages cannot be edited as movable stages.') if stage.system_stage?

    stage.assign_attributes(movable_stage_attributes(stage, row))
    stage.default = false unless stage.active?
    stage.save!
    replace_field_requirements!(stage, row) if row.key?(:field_requirements)
    stage.id
  end

  def find_or_build_movable_stage(row)
    return pipeline.stages.lock.find(row[:id]) if row[:id].present?

    pipeline.stages.new(account: pipeline.account)
  end

  def movable_stage_attributes(stage, row)
    {
      name: row[:name],
      color: row[:color].presence || stage.color,
      active: row.key?(:active) ? ActiveModel::Type::Boolean.new.cast(row[:active]) : stage.active,
      default: boolean_value(row, :default, stage.default),
      outcome: 'open',
      transition_reason_options: row.key?(:transition_reason_options) ? row[:transition_reason_options] : stage.transition_reason_options,
      transition_reason_required: boolean_value(row, :transition_reason_required, stage.transition_reason_required)
    }
  end

  def update_technical_stage!
    row = attributes[:technical_stage].to_h
    return if row.blank?

    stage = pipeline.stages.lock.find(row[:id])
    raise_stage_error!('INVALID_TECHNICAL_STAGE', 'The selected stage is not a technical stage.') unless stage.technical_stage?

    active = ActiveModel::Type::Boolean.new.cast(row[:active])
    Crm::Stages::UnsortedDeactivationGuard.ensure_empty!(stage) if !active && stage.active?
    stage.update!(active: active, default: active ? stage.default : false)
  end

  def update_terminal_stages!
    terminal_stage_rows.each do |row|
      stage = pipeline.stages.lock.find(row[:id])
      raise_stage_error!('INVALID_TERMINAL_STAGE', 'The selected stage is not terminal.') unless stage.terminal_outcome?

      stage.update!(
        name: row[:name],
        closing_reason_options: row.key?(:closing_reason_options) ? row[:closing_reason_options] : stage.closing_reason_options,
        closing_reason_required: boolean_value(row, :closing_reason_required, stage.closing_reason_required)
      )
      replace_field_requirements!(stage, row) if row.key?(:field_requirements)
    end
  end

  def update_pipeline_rules!
    rules = attributes[:pipeline_rules].to_h
    return if rules.blank?

    pipeline.update!(rules.slice(:restrict_stage_skipping, :restrict_backward_move, :allow_stage_rule_override))
  end

  def replace_field_requirements!(stage, row)
    Crm::Stages::ReplaceFieldRequirementsService.new(
      stage: stage,
      requirements: row[:field_requirements]
    ).perform
  end

  def validate_default_selection!(rows)
    selected = rows.select { |row| boolean_value(row, :default, false) }
    invalid = selected.length > 1 || selected.any? { |row| !boolean_value(row, :active, true) }
    return unless invalid

    raise_stage_error!('INVALID_STAGE_DRAFT', 'Choose at most one active open stage as the default.')
  end

  def validate_movable_stage_draft!
    Crm::Stages::MovableStageDraftValidator.new(pipeline: pipeline, attributes: attributes).validate!
  end

  def validate_terminal_stage_draft!
    rows = terminal_stage_rows
    ids = rows.map { |row| normalized_id(row[:id]) }
    expected_ids = pipeline.stages.where(outcome: ::Crm::Stage::TERMINAL_OUTCOMES).pluck(:id)
    return if ids.none?(&:nil?) && ids.uniq.length == ids.length && ids.sort == expected_ids.sort

    raise_stage_error!('INVALID_STAGE_DRAFT', 'The terminal-stage draft must include each terminal stage in this pipeline exactly once.')
  end

  def clear_existing_default!
    pipeline.stages.where(outcome: 'open', default: true).find_each { |stage| stage.update!(default: false) }
  end

  def ensure_complete_stage_order!(ordered_stage_ids)
    expected_stage_ids = movable_stages_scope.pluck(:id)
    return if ordered_stage_ids.length == expected_stage_ids.length && ordered_stage_ids.sort == expected_stage_ids.sort

    raise_stage_error!(
      'INVALID_STAGE_ORDER',
      'Stage order must contain every movable stage in this pipeline exactly once.'
    )
  end

  def persist_stage_order!(ordered_stage_ids)
    stages_by_id = movable_stages_scope.index_by(&:id)
    ordered_stage_ids.each_with_index do |stage_id, index|
      stages_by_id.fetch(stage_id).update!(position: index + 1)
    end

    pipeline.stages.where(code: Crm::Stage::TECHNICAL_STAGE_CODES).find_each do |stage|
      stage.update!(position: 0) unless stage.position.zero?
    end
    pipeline.stages.where(outcome: Crm::Stage::TERMINAL_OUTCOMES).ordered.each_with_index do |stage, index|
      stage.update!(position: ordered_stage_ids.length + index + 1)
    end
  end

  def ensure_active_default_stage!
    active_open_stages = pipeline.stages.active.where(outcome: 'open')
    current_default = active_open_stages.find_by(default: true)
    movable_active_stages = active_open_stages.where.not(code: ::Crm::Stage::TECHNICAL_STAGE_CODES)
    return if current_default.present? && movable_active_stages.exists?

    replacement = movable_active_stages.ordered.first
    raise_stage_error!('DEFAULT_STAGE_REQUIRES_FALLBACK', 'At least one active open stage is required.') if replacement.blank?

    replacement.update!(default: true)
  end

  def movable_stages_scope
    pipeline.stages.where(outcome: 'open').where.not(code: Crm::Stage::TECHNICAL_STAGE_CODES)
  end

  def deleted_stage_ids
    Array(attributes[:deleted_stage_ids]).map(&:to_i).uniq
  end

  def stage_rows
    Array(attributes[:stages]).map { |row| row.to_h.deep_symbolize_keys }
  end

  def terminal_stage_rows
    Array(attributes[:terminal_stages]).map { |row| row.to_h.deep_symbolize_keys }
  end

  def normalized_id(value)
    return if value.blank?
    return value.to_i if value.to_s.match?(/\A\d+\z/)

    nil
  end

  def boolean_value(row, key, fallback)
    row.key?(key) ? ActiveModel::Type::Boolean.new.cast(row[key]) : fallback
  end

  def raise_stage_error!(code, message, stage = nil)
    details = { stage_id: stage.id } if stage
    raise Crm::Error.new(code: code, message: message, status: :unprocessable_content, details: details)
  end
end
