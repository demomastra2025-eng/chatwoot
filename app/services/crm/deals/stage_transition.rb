class Crm::Deals::StageTransition
  Context = Data.define(
    :account,
    :actor,
    :correlation_id,
    :deal,
    :params,
    :requested_position,
    :target_stage
  )

  def initialize(context)
    @context = context
  end

  def perform(closing_reasons)
    previous = previous_stage_state
    assign_stage!(closing_reasons)
    update_stage_visit!(previous[:stage_id])
    reposition_deal!(previous[:stage_id])
    record_event!(previous)
    deal.reload
  end

  private

  attr_reader :context

  delegate :account, :actor, :correlation_id, :deal, :params, :requested_position, :target_stage, to: :context

  def previous_stage_state
    {
      stage_id: deal.stage_id,
      pipeline_id: deal.pipeline_id,
      closing_reasons: deal.closing_reasons
    }
  end

  def assign_stage!(closing_reasons)
    deal.assign_attributes(
      stage: target_stage,
      pipeline: target_stage.pipeline,
      position: requested_position.presence || deal.position,
      closed_at: target_stage.outcome_open? ? nil : Time.zone.now,
      closing_reasons: closing_reasons
    )
    clear_waiting_state unless target_stage.outcome_open?
    deal.save!
  end

  def update_stage_visit!(from_stage_id)
    ::Crm::StageVisits::Tracker.transition!(
      deal: deal,
      from_stage_id: from_stage_id,
      correlation_id: correlation_id
    )
  end

  def reposition_deal!(from_stage_id)
    ::Crm::BoardPositioner.place!(
      scope: account.crm_deals.kept.where(stage_id: target_stage.id),
      record: deal,
      target_position: requested_position
    )
    return if from_stage_id == target_stage.id

    ::Crm::BoardPositioner.normalize!(scope: account.crm_deals.kept.where(stage_id: from_stage_id))
  end

  def record_event!(previous)
    ::Crm::Events::Writer.record!(
      account: account,
      eventable: deal,
      actor: actor,
      event_type: 'deal_stage_changed',
      correlation_id: correlation_id,
      causation_id: params[:causation_id],
      command_key: params[:idempotency_key],
      meta: event_meta(previous),
      before_data: previous,
      after_data: current_stage_state
    )
  end

  def event_meta(previous)
    {
      command_type: params[:command_type].presence || 'transition',
      command_fingerprint: command_fingerprint,
      from_stage_id: previous[:stage_id],
      to_stage_id: target_stage.id,
      from_pipeline_id: previous[:pipeline_id],
      to_pipeline_id: target_stage.pipeline_id,
      from_closing_reasons: previous[:closing_reasons],
      closing_reasons: deal.closing_reasons,
      stage_rule_override: params[:stage_rule_override]
    }.compact
  end

  def current_stage_state
    {
      stage_id: target_stage.id,
      pipeline_id: target_stage.pipeline_id,
      closing_reasons: deal.closing_reasons
    }
  end

  def command_fingerprint
    params.fetch(:command_fingerprint)
  end

  def clear_waiting_state
    deal.assign_attributes(
      waiting_until: nil,
      waiting_reason: nil,
      waiting_started_at: nil,
      waiting_set_by: nil
    )
  end
end
