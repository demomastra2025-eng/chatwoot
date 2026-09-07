class Crm::Deals::TransitionService < Crm::BaseWriteService
  def initialize(account:, deal:, params:, actor: nil)
    @deal = deal
    super(account: account, params: params, record: @deal, actor: actor)
  end

  def perform
    prepare_transition!
    saved_deal = ApplicationRecord.transaction { persist_transition! }
    publish_transition(saved_deal) if @realtime_event_name.present?
    saved_deal
  end

  private

  attr_reader :deal

  def prepare_transition!
    @correlation_id = SecureRandom.uuid
    @target_stage = account.crm_stages.find(params[:stage_id])
    @requested_position = resolve_requested_position
    @command_fingerprint = command_fingerprint(@target_stage)
  end

  def persist_transition!
    deal.lock!
    idempotent_deal = find_idempotent_deal(@command_fingerprint)
    return idempotent_deal if idempotent_deal

    assert_lock_version!
    @stage_changing = deal.stage_id != @target_stage.id
    return deal unless transition_requested?

    prepare_stage_change! if @stage_changing
    apply_transition!
    cancel_open_tasks!(@correlation_id) if closing_command?
    @realtime_event_name = realtime_event_name
    deal.reload
  end

  def transition_requested?
    @stage_changing || @requested_position.present? || params.key?(:closing_reasons)
  end

  def prepare_stage_change!
    ensure_stage_entry_rules!(@target_stage)
    ::Crm::StageVisits::Tracker.ensure_initial!(
      deal: deal,
      correlation_id: @correlation_id,
      estimated: true
    )
  end

  def apply_transition!
    closing_reasons = resolve_closing_reasons!(
      target_stage: @target_stage,
      current_reasons: deal.closing_reasons,
      require_input: @stage_changing
    )
    ensure_closing_reason_present!(@target_stage, closing_reasons)
    Crm::Deals::StageTransition.new(stage_transition_context).perform(closing_reasons)
  end

  def stage_transition_context
    Crm::Deals::StageTransition::Context.new(
      account: account,
      actor: actor,
      correlation_id: @correlation_id,
      deal: deal,
      params: params.to_h.symbolize_keys.merge(
        command_fingerprint: @command_fingerprint,
        stage_rule_override: @stage_rule_override
      ),
      requested_position: @requested_position,
      target_stage: @target_stage
    )
  end

  def closing_command?
    params[:command_type].in?(%w[close_won close_lost])
  end

  def realtime_event_name
    @stage_changing ? Events::Types::CRM_DEAL_STAGE_CHANGED : Events::Types::CRM_DEAL_UPDATED
  end

  def publish_transition(saved_deal)
    event_type = @stage_changing ? 'deal_stage_changed' : 'deal_updated'
    Crm::AfterCommit.run do
      dispatch_crm_deal_realtime_event!(@realtime_event_name, saved_deal.reload, meta: { event_type: event_type })
    end
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

  def resolve_requested_position
    return unless params.key?(:position)

    resolve_integer(:position, current: deal.position, allow_nil: true)
  end
end
