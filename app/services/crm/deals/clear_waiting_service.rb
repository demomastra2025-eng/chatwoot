class Crm::Deals::ClearWaitingService < Crm::BaseWriteService
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
      next deal unless deal.waiting?

      clear_waiting!
      changed = true
      deal.reload
    end

    dispatch_waiting_update(saved_deal) if changed
    saved_deal
  end

  private

  attr_reader :deal

  def clear_waiting!
    before_data = waiting_data
    deal.update!(waiting_until: nil, waiting_reason: nil, waiting_started_at: nil, waiting_set_by: nil)
    record_waiting_event!(before_data)
  end

  def record_waiting_event!(before_data)
    Crm::Events::Writer.record!(
      account: account,
      eventable: deal,
      actor: actor,
      event_type: 'deal_waiting_cleared',
      command_key: params[:idempotency_key],
      meta: { command_fingerprint: command_fingerprint },
      before_data: before_data,
      after_data: waiting_data
    )
  end

  def command_fingerprint
    @command_fingerprint ||= Digest::SHA256.hexdigest({ command_type: 'clear_waiting' }.to_json)
  end

  def find_idempotent_deal
    return if params[:idempotency_key].blank?

    event = deal.events.find_by(command_key: params[:idempotency_key])
    return unless event
    return deal.reload if event.meta['command_fingerprint'] == command_fingerprint

    raise Crm::Error.new(
      code: 'IDEMPOTENCY_KEY_REUSED',
      message: 'Idempotency key was already used by another command',
      status: :conflict,
      details: { idempotency_key: params[:idempotency_key] }
    )
  end

  def dispatch_waiting_update(saved_deal)
    dispatch_crm_deal_realtime_event!(
      Events::Types::CRM_DEAL_UPDATED,
      saved_deal,
      meta: { event_type: 'deal_waiting_cleared' }
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
end
