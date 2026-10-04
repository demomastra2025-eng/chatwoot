class Crm::Stages::MovableStageDraftValidator
  def initialize(pipeline:, attributes:)
    @pipeline = pipeline
    @attributes = attributes.to_h.deep_symbolize_keys
  end

  def validate!
    current_ids = movable_stages_scope.lock.pluck(:id)
    deleted_ids = normalize_ids(Array(attributes[:deleted_stage_ids]))
    submitted_ids = normalize_ids(submitted_stage_values)
    ensure_unique_valid_ids!(deleted_ids, submitted_ids)

    remaining_ids = current_ids - deleted_ids
    ensure_ids_in_scope!(current_ids, remaining_ids, deleted_ids, submitted_ids)
    ensure_complete_order!(remaining_ids, submitted_ids)
  end

  private

  attr_reader :pipeline, :attributes

  def movable_stages_scope
    pipeline.stages.where(outcome: 'open').where.not(code: ::Crm::Stage::TECHNICAL_STAGE_CODES)
  end

  def submitted_stage_values
    Array(attributes[:stages]).filter_map do |row|
      value = row.to_h.deep_symbolize_keys[:id]
      (value.presence)
    end
  end

  def normalize_ids(values)
    values.map { |value| normalized_id(value) }
  end

  def normalized_id(value)
    return if value.blank?
    return value.to_i if value.to_s.match?(/\A\d+\z/)

    nil
  end

  def ensure_unique_valid_ids!(deleted_ids, submitted_ids)
    valid_ids = deleted_ids.none?(&:nil?) && submitted_ids.none?(&:nil?)
    unique_ids = deleted_ids.uniq.length == deleted_ids.length &&
                 submitted_ids.uniq.length == submitted_ids.length
    raise_invalid_order! unless valid_ids && unique_ids
  end

  def ensure_ids_in_scope!(current_ids, remaining_ids, deleted_ids, submitted_ids)
    invalid_scope = (deleted_ids - current_ids).present? || (submitted_ids - remaining_ids).present?
    raise_invalid_order! if invalid_scope
  end

  def ensure_complete_order!(remaining_ids, submitted_ids)
    raise_invalid_order! unless submitted_ids.sort == remaining_ids.sort
  end

  def raise_invalid_order!
    raise Crm::Error.new(
      code: 'INVALID_STAGE_ORDER',
      message: 'Stage order must contain every movable stage in this pipeline exactly once.',
      status: :unprocessable_content
    )
  end
end
