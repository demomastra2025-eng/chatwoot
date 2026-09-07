class Crm::Deals::SetWaitingService < Crm::BaseWriteService
  def initialize(account:, deal:, params:, actor: nil)
    @deal = deal
    super(account: account, params: params, record: @deal, actor: actor)
  end

  def perform
    changed = false
    saved_deal = ApplicationRecord.transaction do
      deal.lock!
      idempotent_deal = find_idempotent_deal
      next idempotent_deal if idempotent_deal

      assert_lock_version!
      ensure_open_deal!
      changed = true
      persist_waiting!
    end

    dispatch_waiting_update(saved_deal) if changed
    saved_deal
  end

  private

  attr_reader :deal

  def persist_waiting!
    waiting_until = resolve_waiting_until!
    before_data = waiting_data
    update_waiting!(waiting_until)
    wake_up_task = create_wake_up_task!(waiting_until)
    record_waiting_event!(before_data, wake_up_task)
    deal.reload
  end

  def update_waiting!(waiting_until)
    deal.update!(
      waiting_until: waiting_until,
      waiting_reason: resolve_waiting_reason!,
      waiting_started_at: Time.zone.now,
      waiting_set_by: actor
    )
  end

  def record_waiting_event!(before_data, wake_up_task)
    Crm::Events::Writer.record!(
      account: account,
      eventable: deal,
      actor: actor,
      event_type: 'deal_waiting_set',
      command_key: params[:idempotency_key],
      meta: {
        command_fingerprint: command_fingerprint,
        wake_up_task_id: wake_up_task&.id
      }.compact,
      before_data: before_data,
      after_data: waiting_data
    )
  end

  def ensure_open_deal!
    validation_error!('deal', 'must be open to enter waiting') if deal.closed?
  end

  def resolve_waiting_until!
    value = resolve_datetime(:waiting_until, current: nil)
    validation_error!('waiting_until', 'is required') if value.blank?
    validation_error!('waiting_until', 'must be in the future') unless value > Time.zone.now

    value
  end

  def resolve_waiting_reason!
    value = resolve_optional_text(:waiting_reason, current: nil)
    validation_error!('waiting_reason', 'is required') if value.blank?

    value
  end

  def create_wake_up_task!(waiting_until)
    return unless create_wake_up_task?

    validation_error!('create_wake_up_task', 'requires CRM tasks') unless account.feature_enabled?('crm_tasks')
    title = resolve_optional_text(:wake_up_task_title, current: nil)
    validation_error!('wake_up_task_title', 'is required') if title.blank?

    Crm::Tasks::UpsertService.new(
      account: account,
      actor: actor,
      broadcast_linked_deal: false,
      params: wake_up_task_params(waiting_until, title)
    ).perform
  end

  def wake_up_task_params(waiting_until, title)
    {
      deal_id: deal.id,
      title: title,
      due_at: waiting_until.iso8601,
      assignee_id: deal.owner_id,
      team_id: deal.team_id
    }
  end

  def create_wake_up_task?
    ActiveModel::Type::Boolean.new.cast(params[:create_wake_up_task])
  end

  def command_fingerprint
    @command_fingerprint ||= Digest::SHA256.hexdigest(
      {
        waiting_until: params[:waiting_until].to_s,
        waiting_reason: params[:waiting_reason].to_s.strip,
        create_wake_up_task: create_wake_up_task?,
        wake_up_task_title: params[:wake_up_task_title].to_s.strip.presence
      }.to_json
    )
  end

  def find_idempotent_deal
    return if params[:idempotency_key].blank?

    event = deal.events.find_by(command_key: params[:idempotency_key])
    return unless event
    return deal.reload if event.meta['command_fingerprint'] == command_fingerprint

    raise Crm::Error.new(
      code: 'IDEMPOTENCY_KEY_REUSED',
      message: 'Idempotency key was already used with different waiting parameters',
      status: :conflict,
      details: { idempotency_key: params[:idempotency_key] }
    )
  end

  def waiting_data
    {
      waiting_until: deal.waiting_until&.iso8601,
      waiting_reason: deal.waiting_reason,
      waiting_started_at: deal.waiting_started_at&.iso8601,
      waiting_set_by_id: deal.waiting_set_by_id
    }
  end

  def dispatch_waiting_update(saved_deal)
    dispatch_crm_deal_realtime_event!(
      Events::Types::CRM_DEAL_UPDATED,
      saved_deal,
      meta: { event_type: 'deal_waiting_set' }
    )
  end
end
