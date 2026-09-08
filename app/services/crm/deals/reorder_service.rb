class Crm::Deals::ReorderService < Crm::BaseWriteService
  def initialize(account:, deal:, params:, actor: nil)
    @deal = deal
    super(account: account, params: params, record: deal, actor: actor)
  end

  def perform
    changed = false
    saved_deal = ApplicationRecord.transaction do
      deal.lock!
      target_position = resolve_integer(:position, current: deal.position)
      fingerprint = Digest::SHA256.hexdigest({ command_type: 'reorder', position: target_position }.to_json)
      event = deal.events.find_by(command_key: params[:idempotency_key]) if params[:idempotency_key].present?
      if event
        unless event.meta['command_fingerprint'] == fingerprint
          raise Crm::Error.new(
            code: 'IDEMPOTENCY_KEY_REUSED',
            message: 'Idempotency key was already used with different command parameters',
            status: :conflict
          )
        end
        next deal.reload
      end

      assert_lock_version!
      next deal if target_position == deal.position

      from_position = deal.position
      Crm::BoardPositioner.place!(
        scope: account.crm_deals.kept.where(stage_id: deal.stage_id),
        record: deal,
        target_position: target_position
      )
      deal.reload.update!(updated_at: Time.current)
      deal.reload
      changed = true
      Crm::Events::Writer.record!(
        account: account,
        eventable: deal,
        actor: actor,
        event_type: 'deal_updated',
        command_key: params[:idempotency_key],
        meta: {
          command_type: 'reorder',
          command_fingerprint: fingerprint,
          from_position: from_position,
          to_position: deal.reload.position
        },
        before_data: { position: from_position },
        after_data: { position: deal.position }
      )
      deal.reload
    end

    dispatch_crm_deal_realtime_event!(Events::Types::CRM_DEAL_UPDATED, saved_deal, meta: { event_type: 'deal_updated' }) if changed
    saved_deal
  end

  private

  attr_reader :deal
end
