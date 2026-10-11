class Crm::Pipelines::UpdateService
  def initialize(pipeline:, attributes:, stage_draft: nil, auto_create_stage_id: nil, pipeline_order: nil)
    @pipeline = pipeline
    @attributes = attributes.to_h.deep_symbolize_keys
    @stage_draft = stage_draft
    @auto_create_stage_id = auto_create_stage_id
    @pipeline_order = pipeline_order
    @stage_id_map = {}
  end

  def perform
    ApplicationRecord.transaction do
      # Match pipeline default updates: account first, then the pipeline/stages.
      account.lock!
      pipeline.lock!
      was_default = pipeline.active? && pipeline.default?
      apply_stage_draft!
      set_auto_create_stage!
      pipeline.update!(resolved_attributes)
      persist_pipeline_order! unless pipeline_order.nil?
      promote_default_pipeline! if was_default && (!pipeline.active? || !pipeline.default?)
    end
    pipeline.reload
  end

  private

  attr_reader :pipeline, :attributes, :stage_draft, :auto_create_stage_id, :pipeline_order, :stage_id_map

  def account
    pipeline.account
  end

  def apply_stage_draft!
    return if stage_draft.nil?

    service = Crm::Stages::BatchUpdateService.new(pipeline: pipeline, attributes: stage_draft)
    service.perform
    @stage_id_map = service.stage_id_map
  end

  def resolved_attributes
    return attributes unless attributes.key?(:appointment_automation)

    previous = pipeline.appointment_automation.to_h.deep_stringify_keys
    config = previous.merge(attributes[:appointment_automation].to_h.deep_stringify_keys)
    if config['rules'].is_a?(Array) && (config['rules'] != previous['rules'] || stage_id_map.present?)
      config['rules'] = config['rules'].map do |rule|
        next rule unless rule.is_a?(Hash)

        rule['stage_id'].present? ? rule.merge('stage_id' => resolve_stage_reference!(rule['stage_id'])) : rule
      end
    end
    attributes.merge(appointment_automation: config)
  end

  def set_auto_create_stage!
    return if auto_create_stage_id.blank?

    stage_id = resolve_stage_reference!(auto_create_stage_id)
    stage = pipeline.stages.active.find_by(id: stage_id, outcome: 'open')
    unless stage
      raise Crm::Error.new(
        code: 'INVALID_AUTO_CREATE_STAGE', message: 'Auto-created deals require an active open stage from the selected pipeline.',
        status: :unprocessable_content
      )
    end
    stage.update!(default: true)
  end

  def resolve_stage_reference!(value)
    return stage_id_map.fetch(value) if stage_id_map.key?(value)
    return value.to_i if value.to_s.match?(/\A\d+\z/)

    raise Crm::Error.new(
      code: 'INVALID_STAGE_REFERENCE', message: 'Select a stage ID or a new stage client ID from this draft.',
      status: :unprocessable_content
    )
  end

  def promote_default_pipeline!
    account.crm_pipelines.active.ordered.lock.first&.update!(default: true)
  end

  def persist_pipeline_order!
    records = account.crm_pipelines.active.lock.to_a
    ids = Array(pipeline_order).map { |id| id.to_i if id.to_s.match?(/\A[1-9]\d*\z/) }
    unless pipeline_order.is_a?(Array) && ids.none?(&:nil?) && ids.length == records.length && ids.sort == records.map(&:id).sort
      raise Crm::Error.new(
        code: 'INVALID_PIPELINE_ORDER', message: 'Pipeline order must contain every active pipeline in this account exactly once.',
        status: :unprocessable_content
      )
    end

    by_id = records.index_by(&:id)
    ids.each_with_index { |id, index| by_id.fetch(id).update!(position: (index + 1) * 10) }
  end
end
