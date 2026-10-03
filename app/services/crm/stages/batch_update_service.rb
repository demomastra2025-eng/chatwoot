class Crm::Stages::BatchUpdateService
  def initialize(pipeline:, attributes:)
    @pipeline = pipeline
    @attributes = attributes.to_h.deep_symbolize_keys
  end

  def perform
    pipeline.with_lock do
      open_stages = open_stages_scope.lock.to_a
      terminal_stages = terminal_stages_scope.lock.to_a
      stage_rows = normalized_rows(:stages)
      terminal_rows = normalized_rows(:terminal_stages)
      deleted_ids = normalized_ids(:deleted_stage_ids)

      validate_open_stage_draft!(open_stages, stage_rows, deleted_ids)
      validate_terminal_stage_draft!(terminal_stages, terminal_rows)
      validate_default_selection!(stage_rows)
      validate_deletions!(open_stages, deleted_ids)

      open_stages_scope.where(default: true).update_all(default: false)
      deleted_ids.each { |id| open_stages.find { |stage| stage.id == id }.destroy! }

      saved_stages = stage_rows.map.with_index do |row, index|
        stage = if row[:id].present?
                  open_stages.find { |item| item.id == normalized_id(row[:id]) }
                else
                  pipeline.stages.new(account: pipeline.account)
                end
        stage.assign_attributes(open_stage_attributes(row, stage, index))
        stage.save!
        stage
      end

      update_terminal_stages!(terminal_stages, terminal_rows, saved_stages.length)
      ensure_active_default_stage!(stage_rows, saved_stages)
    end

    pipeline.reload
  end

  private

  attr_reader :pipeline, :attributes

  def open_stages_scope
    ::Crm::Stage.where(pipeline_id: pipeline.id, outcome: 'open').order(:position, :id)
  end

  def terminal_stages_scope
    ::Crm::Stage.where(pipeline_id: pipeline.id, outcome: ::Crm::Stage::TERMINAL_OUTCOMES).order(:position, :id)
  end

  def normalized_rows(key)
    rows = attributes[key]
    return [] unless rows.is_a?(Array)

    rows.map { |row| row.to_h.deep_symbolize_keys }
  end

  def normalized_ids(key)
    values = attributes[key]
    return [] unless values.is_a?(Array)

    values.map do |value|
      value.to_s.match?(/\A\d+\z/) ? value.to_i : nil
    end
  end

  def validate_open_stage_draft!(open_stages, rows, deleted_ids)
    required_keys = %i[name color active default transition_reason_options transition_reason_required]
    invalid_shape = rows.any? { |row| (required_keys - row.keys).any? }
    row_ids = rows.filter_map do |row|
      next if row[:id].blank?

      normalized_id(row[:id])
    end
    existing_ids = open_stages.map(&:id)
    invalid_row_id = rows.any? { |row| row[:id].present? && normalized_id(row[:id]).nil? }
    return if !invalid_shape && !invalid_row_id && row_ids.uniq.length == row_ids.length &&
              deleted_ids.none?(&:nil?) && deleted_ids.uniq.length == deleted_ids.length &&
              (row_ids & deleted_ids).empty? &&
              (row_ids + deleted_ids).sort == existing_ids.sort

    raise_stage_error!('INVALID_STAGE_ORDER', 'The stage draft must include every existing open stage once, either edited or deleted.')
  end

  def validate_terminal_stage_draft!(terminal_stages, rows)
    row_ids = rows.map { |row| normalized_id(row[:id]) }
    expected_ids = terminal_stages.map(&:id)
    required_keys = %i[name closing_reason_options closing_reason_required]
    invalid_shape = rows.any? { |row| (required_keys - row.keys).any? }
    return if !invalid_shape && row_ids.none?(&:nil?) && row_ids.uniq.length == row_ids.length && row_ids.sort == expected_ids.sort

    raise_stage_error!('INVALID_STAGE_DRAFT', 'The stage draft must include each terminal stage in this pipeline exactly once.')
  end

  def validate_default_selection!(rows)
    selected = rows.select do |row|
      ActiveModel::Type::Boolean.new.cast(row[:default])
    end
    return if selected.length <= 1 && selected.all? do |row|
      ActiveModel::Type::Boolean.new.cast(row[:active])
    end

    raise_stage_error!('INVALID_STAGE_DRAFT', 'Choose one active open stage as the default.')
  end

  def validate_deletions!(open_stages, deleted_ids)
    deleted_ids.each do |id|
      stage = open_stages.find { |item| item.id == id }
      next if stage.deals.none?

      raise_stage_error!(
        'STAGE_HAS_DEALS',
        'You cannot delete a stage while it still has deals. Move all open and closed deals to another stage first.'
      )
    end
  end

  def open_stage_attributes(row, stage, index)
    {
      active: boolean_value(row, :active, stage.active),
      color: row[:color].presence || stage.color,
      default: false,
      name: row.key?(:name) ? row[:name] : stage.name,
      outcome: 'open',
      position: index + 1,
      transition_reason_options: row.key?(:transition_reason_options) ? row[:transition_reason_options] : stage.transition_reason_options,
      transition_reason_required: boolean_value(row, :transition_reason_required, stage.transition_reason_required),
    }
  end

  def update_terminal_stages!(terminal_stages, rows, open_stage_count)
    rows_by_id = rows.index_by { |row| normalized_id(row[:id]) }
    terminal_stages.each_with_index do |stage, index|
      row = rows_by_id.fetch(stage.id)
      stage.update!(
        name: row.key?(:name) ? row[:name] : stage.name,
        closing_reason_options: row.key?(:closing_reason_options) ? row[:closing_reason_options] : stage.closing_reason_options,
        closing_reason_required: boolean_value(row, :closing_reason_required, stage.closing_reason_required),
        position: open_stage_count + index + 1
      )
    end
  end

  def ensure_active_default_stage!(rows, saved_stages)
    active_stages = saved_stages.select(&:active?)
    selected_row_index = rows.index do |row|
      ActiveModel::Type::Boolean.new.cast(row[:default])
    end
    default_stage = selected_row_index ? saved_stages[selected_row_index] : active_stages.first

    raise_stage_error!('DEFAULT_STAGE_REQUIRES_FALLBACK', 'At least one active open stage is required.') if default_stage.blank?

    default_stage.update!(default: true)
  end

  def normalized_id(value)
    return if value.blank?
    return value.to_i if value.to_s.match?(/\A\d+\z/)

    nil
  end

  def boolean_value(row, key, fallback)
    row.key?(key) ? ActiveModel::Type::Boolean.new.cast(row[key]) : fallback
  end

  def raise_stage_error!(code, message)
    raise ::Crm::Error.new(code: code, message: message, status: :unprocessable_content)
  end
end
