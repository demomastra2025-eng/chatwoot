class Crm::Appointments::CandidateScope
  def self.resolve(account:, contact:, pipeline_id: nil)
    return account.crm_deals.none unless contact && contact.account_id == account.id

    linked = Crm::DealContact.where(account_id: account.id, contact_id: contact.id, primary: true).select(:deal_id)
    conversations = account.conversations.where(contact_id: contact.id).select(:id)
    threads = CommunicationThread.where(account_id: account.id, contact_id: contact.id).select(:id)
    base = account.crm_deals.active.where(pipeline_id: account.crm_pipelines.active.select(:id))
    scope = base.where(id: linked).or(base.where(originating_conversation_id: conversations))
                .or(base.where(originating_communication_thread_id: threads))
    pipeline_id.present? ? scope.where(pipeline_id: pipeline_id) : scope
  end
end
