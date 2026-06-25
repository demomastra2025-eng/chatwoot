class Contacts::OwnerSyncService
  def initialize(contact:)
    @contact = contact
  end

  def perform
    return if contact.blank? || contact.destroyed?

    ApplicationRecord.transaction do
      sync_conversations!
      sync_communication_threads!
      sync_primary_contact_deals!
    end
  end

  private

  attr_reader :contact

  def owner_id
    contact.owner_id
  end

  def sync_conversations!
    conversations_requiring_owner_sync.find_each do |conversation|
      attributes = { assignee_id: owner_id }
      attributes[:assignee_agent_bot_id] = nil if owner_id.present?

      conversation.assign_attributes(attributes)
      conversation.save! if conversation.changed?
    end
  end

  def conversations_requiring_owner_sync
    scope = contact.conversations.where(account_id: contact.account_id)
    assignee_scope = records_with_owner_mismatch(scope, :assignee_id)
    return assignee_scope if owner_id.blank?

    assignee_scope.or(scope.where.not(assignee_agent_bot_id: nil))
  end

  def sync_communication_threads!
    threads_requiring_owner_sync.find_each do |thread|
      thread.update!(assignee_id: owner_id)
    end
  end

  def threads_requiring_owner_sync
    scope = CommunicationThread.where(account_id: contact.account_id, contact_id: contact.id)
    records_with_owner_mismatch(scope, :assignee_id)
  end

  def sync_primary_contact_deals!
    primary_contact_deals_requiring_owner_sync.find_each do |deal|
      deal.update!(owner_id: owner_id)
    end
  end

  def primary_contact_deals_requiring_owner_sync
    scope = Crm::Deal.joins(:deal_contacts).where(
      account_id: contact.account_id,
      crm_deal_contacts: {
        account_id: contact.account_id,
        contact_id: contact.id,
        primary: true
      }
    )
    records_with_owner_mismatch(scope, :owner_id)
  end

  def records_with_owner_mismatch(scope, column)
    return scope.where.not(column => nil) if owner_id.blank?

    scope.where(column => nil).or(scope.where.not(column => owner_id))
  end
end
