class Crm::Deals::UndoTransitionService
  WINDOW = 15.minutes

  def initialize(account:, deal:, params:, actor: nil)
    @account = account
    @deal = deal
    @params = params.to_h.deep_symbolize_keys
    @actor = actor
  end

  def perform
    @deal.with_lock do
      source_event = find_source_event
      transition_params = transition_params_for(source_event)
      receipt = find_undo_receipt(transition_params)
      next receipt if receipt.present?

      validate_latest_source_event!(source_event)
      validate_source_event!(source_event)

      Crm::Deals::TransitionService.new(
        account: @account,
        deal: @deal,
        actor: @actor,
        params: transition_params
      ).perform
    end
  end

  private

  def find_source_event
    scope = @deal.events.where(event_type: 'deal_stage_changed')
    scope = scope.where.not("meta->>'command_type' = ?", 'undo_transition')
    return scope.find(@params[:event_id]) if @params[:event_id].present?

    scope.ordered.first!
  end

  def transition_params_for(source_event)
    {
      stage_id: source_event.before_data['stage_id'],
      lock_version: @params[:lock_version],
      idempotency_key: @params[:idempotency_key],
      transition_reason: @params[:transition_reason],
      command_type: 'undo_transition',
      causation_id: source_event.correlation_id
    }.compact
  end

  def find_undo_receipt(transition_params)
    return if transition_params[:idempotency_key].blank?

    event = @deal.events.find_by(command_key: transition_params[:idempotency_key])
    return if event.blank?

    target_stage = @account.crm_stages.find(transition_params[:stage_id])
    return @deal.reload if matching_undo_receipt?(event, transition_params, target_stage)

    raise_idempotency_key_reused!(transition_params)
  end

  def matching_undo_receipt?(event, transition_params, target_stage)
    expected_fingerprint = Crm::Deals::TransitionService.fingerprint_for(
      params: transition_params,
      target_stage_id: target_stage.id,
      position: nil,
      transition_reason: canonical_undo_reason(transition_params, target_stage)
    )
    event.meta['command_type'] == 'undo_transition' &&
      event.meta['command_fingerprint'] == expected_fingerprint
  end

  def canonical_undo_reason(transition_params, target_stage)
    return if transition_params[:transition_reason].blank?

    target_stage.canonical_transition_reason(transition_params[:transition_reason])
  end

  def raise_idempotency_key_reused!(transition_params)
    raise Crm::Error.new(
      code: 'IDEMPOTENCY_KEY_REUSED',
      message: 'Idempotency key was already used with different command parameters',
      status: :conflict,
      details: { idempotency_key: transition_params[:idempotency_key] }
    )
  end

  def validate_latest_source_event!(event)
    latest_event = @deal.events.where(event_type: 'deal_stage_changed')
    latest_event = latest_event.where.not("meta->>'command_type' = ?", 'undo_transition')
    latest_event = latest_event.order(created_at: :desc, id: :desc).first
    return if latest_event&.id == event.id

    raise_not_undoable!
  end

  def validate_source_event!(event)
    valid = event.created_at >= WINDOW.ago && event.after_data['stage_id'].to_i == @deal.stage_id
    return if valid

    raise_not_undoable!
  end

  def raise_not_undoable!
    raise Crm::Error.new(
      code: 'DEAL_TRANSITION_NOT_UNDOABLE',
      message: 'The transition is no longer the current recent transition',
      status: :conflict
    )
  end
end
