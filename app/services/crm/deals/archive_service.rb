class Crm::Deals::ArchiveService < Crm::BaseWriteService
  def initialize(account:, deal:, params:, archived:, actor: nil)
    @deal = deal
    @archived = archived
    super(account: account, params: params, record: @deal, actor: actor)
  end

  def perform
    ApplicationRecord.transaction do
      deal.lock!
      assert_lock_version!

      return deal if archived == deal.archived_at.present?

      archived_at = archived ? Time.zone.now : nil
      deal.update!(archived_at: archived_at)

      ::Crm::Events::Writer.record!(
        account: account,
        eventable: deal,
        actor: actor,
        event_type: archived ? 'deal_archived' : 'deal_unarchived',
        meta: {}
      )

      deal.reload
    end
  end

  private

  attr_reader :deal, :archived
end
