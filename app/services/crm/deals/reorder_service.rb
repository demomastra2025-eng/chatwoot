class Crm::Deals::ReorderService < Crm::BaseWriteService
  def initialize(account:, deal:, params:, actor: nil)
    @deal = deal
    super(account: account, params: params, record: deal, actor: actor)
  end

  def perform
    target_position = resolve_integer(:position, current: deal.position)
    fingerprint = command_fingerprint(target_position)
    saved_deal, changed = ApplicationRecord.transaction { persist_reorder!(target_position, fingerprint) }

    dispatch_crm_deal_realtime_event!(Events::Types::CRM_DEAL_UPDATED, saved_deal, meta: { event_type: 'deal_updated' }) if changed
    saved_deal
  end

  private

  attr_reader :deal

  def command_fingerprint(target_position)
    Digest::SHA256.hexdigest({ command_type: 'reorder', position: target_position }.to_json)
  end

  def persist_reorder!(target_position, fingerprint)
    deal.lock!
    return [deal.reload, false] if replayed_command?(fingerprint)

    assert_lock_version!
    return [deal, false] if target_position == deal.position

    from_position = deal.position
    move_deal!(target_position)
    record_reorder_event!(from_position, fingerprint)
    [deal.reload, true]
  end

  def replayed_command?(fingerprint)
    return false if params[:idempotency_key].blank?

    event = deal.events.find_by(command_key: params[:idempotency_key])
    return false unless event
    return true if event.meta['command_fingerprint'] == fingerprint

    raise Crm::Error.new(
      code: 'IDEMPOTENCY_KEY_REUSED',
      message: 'Idempotency key was already used with different command parameters',
      status: :conflict
    )
  end

  def move_deal!(target_position)
    Crm::BoardPositioner.place!(
      scope: account.crm_deals.kept.where(stage_id: deal.stage_id),
      record: deal,
      target_position: target_position
    )
    deal.reload.update!(updated_at: Time.current)
    deal.reload
  end

  def record_reorder_event!(from_position, fingerprint)
    Crm::Events::Writer.record!(
      account: account,
      eventable: deal,
      actor: actor,
      event_type: 'deal_updated',
      command_key: params[:idempotency_key],
      meta: reorder_event_meta(from_position, fingerprint),
      before_data: { position: from_position },
      after_data: { position: deal.position }
    )
  end

  def reorder_event_meta(from_position, fingerprint)
    {
      command_type: 'reorder',
      command_fingerprint: fingerprint,
      from_position: from_position,
      to_position: deal.reload.position
    }
  end
end
