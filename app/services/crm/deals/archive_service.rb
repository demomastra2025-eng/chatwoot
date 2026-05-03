class Crm::Deals::ArchiveService < Crm::BaseWriteService
  def initialize(account:, deal:, params:, archived:, actor: nil)
    @deal = deal
    @archived = archived
    super(account: account, params: params, record: @deal, actor: actor)
  end

  def perform
    changed = false
    saved_deal = ApplicationRecord.transaction do
      deal.lock!
      assert_lock_version!

      next deal if archived == deal.archived_at.present?

      archived_at = archived ? Time.zone.now : nil
      deal.update!(archived_at: archived_at)
      changed = true

      ::Crm::Events::Writer.record!(
        account: account,
        eventable: deal,
        actor: actor,
        event_type: archived ? 'deal_archived' : 'deal_unarchived',
        meta: {}
      )

      deal.reload
    end

    if changed
      event_name = if archived
                     Events::Types::CRM_DEAL_ARCHIVED
                   else
                     Events::Types::CRM_DEAL_UNARCHIVED
                   end
      event_type = archived ? 'deal_archived' : 'deal_unarchived'
      dispatch_crm_deal_realtime_event!(
        event_name,
        saved_deal,
        meta: { event_type: event_type }
      )
    end
    saved_deal
  end

  private

  attr_reader :deal, :archived
end
