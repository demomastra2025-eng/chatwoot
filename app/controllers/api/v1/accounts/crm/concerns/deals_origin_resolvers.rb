module Api::V1::Accounts::Crm::Concerns::DealsOriginResolvers
  private

  def resolve_originating_conversation(raw_value)
    value = raw_value.to_s.strip
    return if value.blank?

    Current.account.conversations.find_by(id: value) ||
      Current.account.conversations.find_by(display_id: value)
  end

  def resolve_originating_communication_thread(raw_value)
    value = raw_value.to_s.strip
    return if value.blank?

    CommunicationThread.find_by(account_id: Current.account.id, display_id: value) ||
      CommunicationThread.find_by(account_id: Current.account.id, id: value)
  end
end
