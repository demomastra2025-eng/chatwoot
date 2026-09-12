class Crm::Tasks::CustomerScope
  class << self
    def resolve(account:, contact:, communication_thread:)
      return Crm::Task.none unless valid_context?(account, contact, communication_thread)

      conversation_ids = communication_thread.conversations.where(
        account_id: account.id,
        contact_id: contact.id
      ).select(:id)

      account.crm_tasks.customer_visible.kept.where(originating_conversation_id: conversation_ids)
    end

    private

    def valid_context?(account, contact, communication_thread)
      account.present? && contact.present? && communication_thread.present? &&
        contact.account_id == account.id &&
        communication_thread.account_id == account.id &&
        communication_thread.contact_id == contact.id
    end
  end
end
