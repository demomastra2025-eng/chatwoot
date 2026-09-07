class Crm::Deals::ArchiveService < Crm::BaseWriteService
  def initialize(account:, deal:, params:, archived:, actor: nil)
    @deal = deal
    @archived = archived
    super(account: account, params: params, record: @deal, actor: actor)
  end

  def perform
    saved_deal, changed = ApplicationRecord.transaction { persist_archive_state! }
    publish_archive_state(saved_deal) if changed
    saved_deal
  end

  private

  attr_reader :deal, :archived

  def persist_archive_state!
    deal.lock!
    assert_lock_version!
    return [deal, false] if archived == deal.archived_at.present?

    deal.update!(archived_at: archived ? Time.zone.now : nil)
    record_archive_event!
    [deal.reload, true]
  end

  def record_archive_event!
    ::Crm::Events::Writer.record!(
      account: account,
      eventable: deal,
      actor: actor,
      event_type: archive_event_type,
      meta: {},
      before_data: { archived_at: deal.archived_at_before_last_save },
      after_data: { archived_at: deal.archived_at }
    )
  end

  def publish_archive_state(saved_deal)
    dispatch_crm_deal_realtime_event!(realtime_event_type, saved_deal, meta: { event_type: archive_event_type })
  end

  def archive_event_type
    archived ? 'deal_archived' : 'deal_unarchived'
  end

  def realtime_event_type
    archived ? Events::Types::CRM_DEAL_ARCHIVED : Events::Types::CRM_DEAL_UNARCHIVED
  end
end
