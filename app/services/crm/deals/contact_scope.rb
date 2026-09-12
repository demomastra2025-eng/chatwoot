class Crm::Deals::ContactScope
  class << self
    def resolve(account:, contact:)
      return Crm::Deal.none if account.blank? || contact.blank? || contact.account_id != account.id

      relation = account.crm_deals
      linked_deal_ids = Crm::DealContact.where(account_id: account.id, contact_id: contact.id).select(:deal_id)
      conversation_ids = account.conversations.where(contact_id: contact.id).select(:id)
      thread_ids = CommunicationThread.where(account_id: account.id, contact_id: contact.id).select(:id)

      relation.where(id: linked_deal_ids)
              .or(relation.where(originating_conversation_id: conversation_ids))
              .or(relation.where(originating_communication_thread_id: thread_ids))
    end
  end
end
