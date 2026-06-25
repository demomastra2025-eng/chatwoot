class Crm::Deals::TransitionService < Crm::BaseWriteService
  def initialize(account:, deal:, params:, actor: nil)
    @deal = deal
    super(account: account, params: params, record: @deal, actor: actor)
  end

  def perform
    target_stage = account.crm_stages.find(params[:stage_id])
    requested_position = resolve_requested_position
    stage_changing = deal.stage_id != target_stage.id
    closing_reasons_requested = params.key?(:closing_reasons)
    return deal if !stage_changing && requested_position.blank? && !closing_reasons_requested

    realtime_event_name = if stage_changing
                            Events::Types::CRM_DEAL_STAGE_CHANGED
                          else
                            Events::Types::CRM_DEAL_UPDATED
                          end
    saved_deal = ApplicationRecord.transaction do
      deal.lock!
      assert_lock_version!

      closing_reasons = resolve_closing_reasons!(
        target_stage: target_stage,
        current_reasons: deal.closing_reasons,
        require_input: stage_changing
      )
      ensure_required_fields_for_closed_stage!(target_stage)
      transition_to_stage!(target_stage, closing_reasons: closing_reasons)
    end

    event_type = if realtime_event_name == Events::Types::CRM_DEAL_STAGE_CHANGED
                   'deal_stage_changed'
                 else
                   'deal_updated'
                 end
    dispatch_crm_deal_realtime_event!(
      realtime_event_name,
      saved_deal,
      meta: { event_type: event_type }
    )
    saved_deal
  end

  private

  attr_reader :deal

  def transition_to_stage!(target_stage, closing_reasons:)
    from_stage_id = deal.stage_id
    from_pipeline_id = deal.pipeline_id
    from_closing_reasons = deal.closing_reasons
    requested_position = resolve_requested_position

    deal.stage = target_stage
    deal.pipeline = target_stage.pipeline
    deal.position = requested_position if requested_position.present?
    deal.closed_at = target_stage.outcome_open? ? nil : Time.zone.now
    deal.closing_reasons = closing_reasons
    deal.save!

    ::Crm::BoardPositioner.place!(
      scope: account.crm_deals.kept.where(stage_id: target_stage.id),
      record: deal,
      target_position: requested_position
    )
    if from_stage_id != target_stage.id
      ::Crm::BoardPositioner.normalize!(
        scope: account.crm_deals.kept.where(stage_id: from_stage_id)
      )
    end

    ::Crm::Events::Writer.record!(
      account: account,
      eventable: deal,
      actor: actor,
      event_type: 'deal_stage_changed',
      meta: {
        from_stage_id: from_stage_id,
        to_stage_id: target_stage.id,
        from_pipeline_id: from_pipeline_id,
        to_pipeline_id: target_stage.pipeline_id,
        from_closing_reasons: from_closing_reasons,
        closing_reasons: deal.closing_reasons
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

  def resolve_requested_position
    return unless params.key?(:position)

    resolve_integer(:position, current: deal.position, allow_nil: true)
  end
end
