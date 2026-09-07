class Crm::Deals::UndoTransitionService
  WINDOW = 15.minutes

  def initialize(account:, deal:, params:, actor: nil)
    @account = account
    @deal = deal
    @params = params.to_h.deep_symbolize_keys
    @actor = actor
  end

  def perform
    source_event = find_source_event
    validate_source_event!(source_event)

    Crm::Deals::TransitionService.new(
      account: @account,
      deal: @deal,
      actor: @actor,
      params: {
        stage_id: source_event.before_data['stage_id'],
        lock_version: @params[:lock_version],
        idempotency_key: @params[:idempotency_key],
        command_type: 'undo_transition',
        causation_id: source_event.correlation_id
      }
    ).perform
  end

  private

  def find_source_event
    scope = @deal.events.where(event_type: 'deal_stage_changed').where.not("meta->>'command_type' = ?", 'undo_transition')
    return scope.find(@params[:event_id]) if @params[:event_id].present?

    scope.ordered.first!
  end

  def validate_source_event!(event)
    valid = event.created_at >= WINDOW.ago && event.after_data['stage_id'].to_i == @deal.stage_id
    return if valid

    raise Crm::Error.new(
      code: 'DEAL_TRANSITION_NOT_UNDOABLE',
      message: 'The transition is no longer the current recent transition',
      status: :conflict
    )
  end
end
