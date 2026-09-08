class Crm::Deals::TransitionService < Crm::BaseWriteService
  def initialize(account:, deal:, params:, actor: nil)
    @deal = deal
    super(account: account, params: params, record: @deal, actor: actor)
  end

  def perform
    correlation_id = SecureRandom.uuid
    target_stage = account.crm_stages.find(params[:stage_id])
    requested_position = resolve_requested_position
    closing_reasons_requested = params.key?(:closing_reasons)
    realtime_event_name = nil
    saved_deal = ApplicationRecord.transaction do
      deal.lock!
      fingerprint = command_fingerprint(target_stage)
      idempotent_deal = find_idempotent_deal(fingerprint)
      next idempotent_deal if idempotent_deal

      assert_lock_version!
      stage_changing = deal.stage_id != target_stage.id
      next deal if !stage_changing && requested_position.blank? && !closing_reasons_requested

      ensure_stage_entry_rules!(target_stage) if stage_changing

      realtime_event_name = if stage_changing
                              Events::Types::CRM_DEAL_STAGE_CHANGED
                            else
                              Events::Types::CRM_DEAL_UPDATED
                            end
      if stage_changing
        ::Crm::StageVisits::Tracker.ensure_initial!(
          deal: deal,
          correlation_id: correlation_id,
          estimated: true
        )
      end

      closing_reasons = resolve_closing_reasons!(
        target_stage: target_stage,
        current_reasons: deal.closing_reasons,
        require_input: stage_changing
      )
      ensure_closing_reason_present!(target_stage, closing_reasons)
      transition_to_stage!(
        target_stage,
        closing_reasons: closing_reasons,
        correlation_id: correlation_id
      )
      cancel_open_tasks!(correlation_id) if params[:command_type].in?(%w[close_won close_lost])
      deal.reload
    end

    return saved_deal if realtime_event_name.blank?

    event_type = if realtime_event_name == Events::Types::CRM_DEAL_STAGE_CHANGED
                   'deal_stage_changed'
                 else
                   'deal_updated'
                 end
    Crm::AfterCommit.run do
      dispatch_crm_deal_realtime_event!(realtime_event_name, saved_deal.reload, meta: { event_type: event_type })
    end
    saved_deal
  end

  private

  attr_reader :deal

  def transition_to_stage!(target_stage, closing_reasons:, correlation_id:)
    from_stage_id = deal.stage_id
    from_pipeline_id = deal.pipeline_id
    from_closing_reasons = deal.closing_reasons
    requested_position = resolve_requested_position

    deal.stage = target_stage
    deal.pipeline = target_stage.pipeline
    deal.position = requested_position if requested_position.present?
    deal.closed_at = target_stage.outcome_open? ? nil : Time.zone.now
    deal.closing_reasons = closing_reasons
    clear_waiting_state unless target_stage.outcome_open?
    deal.save!

    ::Crm::StageVisits::Tracker.transition!(
      deal: deal,
      from_stage_id: from_stage_id,
      correlation_id: correlation_id
    )

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
      correlation_id: correlation_id,
      causation_id: params[:causation_id],
      command_key: params[:idempotency_key],
      meta: {
        command_type: params[:command_type].presence || 'transition',
        command_fingerprint: command_fingerprint(target_stage),
        from_stage_id: from_stage_id,
        to_stage_id: target_stage.id,
        from_pipeline_id: from_pipeline_id,
        to_pipeline_id: target_stage.pipeline_id,
        from_closing_reasons: from_closing_reasons,
        closing_reasons: deal.closing_reasons,
        stage_rule_override: @stage_rule_override
      }.compact,
      before_data: {
        stage_id: from_stage_id,
        pipeline_id: from_pipeline_id,
        closing_reasons: from_closing_reasons
      },
      after_data: {
        stage_id: target_stage.id,
        pipeline_id: target_stage.pipeline_id,
        closing_reasons: deal.closing_reasons
      }
    )

    deal.reload
  end

  def ensure_stage_entry_rules!(target_stage)
    @stage_rule_override = Crm::Deals::StageEntryPolicy.new(
      deal: deal,
      target_stage: target_stage,
      account: account,
      actor: actor,
      override_requested: params[:override],
      override_reason: params[:override_reason]
    ).enforce!
  end

  def command_fingerprint(target_stage)
    payload = {
      command_type: params[:command_type].presence || 'transition',
      stage_id: target_stage.id,
      position: resolve_requested_position,
      closing_reasons: Array(params[:closing_reasons]).map(&:to_s).sort,
      override_reason: params[:override_reason].to_s.strip.presence
    }
    Digest::SHA256.hexdigest(payload.to_json)
  end

  def find_idempotent_deal(fingerprint)
    return if params[:idempotency_key].blank?

    event = deal.events.find_by(command_key: params[:idempotency_key])
    return unless event
    return deal.reload if event.meta['command_fingerprint'] == fingerprint

    raise ::Crm::Error.new(
      code: 'IDEMPOTENCY_KEY_REUSED',
      message: 'Idempotency key was already used with different command parameters',
      status: :conflict,
      details: { idempotency_key: params[:idempotency_key] }
    )
  end

  def ensure_closing_reason_present!(target_stage, closing_reasons)
    return unless params[:command_type] == 'close_lost'
    return unless target_stage.closing_reason_required?
    return if closing_reasons.present?

    validation_error!('closing_reasons', 'must be selected for this Lost stage')
  end

  def cancel_open_tasks!(correlation_id)
    deal.tasks.kept.joins(:status).where(crm_task_statuses: { category: %w[open in_progress] }).find_each do |task|
      task.with_lock do
        next if task.archived_at.present? || task.completed? || task.cancelled?

        Crm::Tasks::CancelService.new(
          account: account, task: task, actor: actor, correlation_id: correlation_id,
          params: { lock_version: task.lock_version, cancellation_reason: 'deal_closed' }
        ).perform
      end
    end
  end

  def clear_waiting_state
    deal.assign_attributes(
      waiting_until: nil,
      waiting_reason: nil,
      waiting_started_at: nil,
      waiting_set_by: nil
    )
  end

  def resolve_requested_position
    return unless params.key?(:position)

    resolve_integer(:position, current: deal.position, allow_nil: true)
  end
end
