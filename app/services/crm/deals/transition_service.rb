class Crm::Deals::TransitionService < Crm::BaseWriteService
  def initialize(account:, deal:, params:, actor: nil)
    @deal = deal
    super(account: account, params: params, record: @deal, actor: actor)
  end

  def perform
    target_stage = account.crm_stages.find(params[:stage_id])
    return deal if deal.stage_id == target_stage.id

    ApplicationRecord.transaction do
      deal.lock!
      assert_lock_version!

      ensure_required_fields_for_closed_stage!(target_stage)
      transition_to_stage!(target_stage)
    end
  end

  private

  attr_reader :deal

  def transition_to_stage!(target_stage)
    from_stage_id = deal.stage_id
    from_pipeline_id = deal.pipeline_id

    deal.stage = target_stage
    deal.pipeline = target_stage.pipeline
    deal.closed_at = target_stage.outcome_open? ? nil : Time.zone.now
    deal.save!

    ::Crm::Events::Writer.record!(
      account: account,
      eventable: deal,
      actor: actor,
      event_type: 'deal_stage_changed',
      meta: {
        from_stage_id: from_stage_id,
        to_stage_id: target_stage.id,
        from_pipeline_id: from_pipeline_id,
        to_pipeline_id: target_stage.pipeline_id
      }
    )

    deal.reload
  end

  def ensure_required_fields_for_closed_stage!(target_stage)
    return if target_stage.outcome_open?

    inspector = Crm::RequiredFieldsInspector.new(
      account: account,
      entity_kind: 'deal',
      custom_attributes: deal.custom_attributes
    )
    return if inspector.complete?

    raise ::Crm::Error.new(
      code: 'DEAL_STAGE_REQUIRES_FIELDS',
      message: "Complete required fields before moving the deal to a closed stage: #{inspector.missing_field_labels.join(', ')}",
      status: :unprocessable_content,
      details: {
        missing_fields: inspector.missing_field_details
      }
    )
  end
end
