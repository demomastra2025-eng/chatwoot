class Crm::Tasks::ConversationReference
  def initialize(task:, user_context:)
    @task = task
    @user_context = user_context
  end

  def perform
    account = @user_context[:account]
    return if account.blank? || @task.account_id != account.id || @task.originating_conversation_id.blank?

    conversation = account.conversations.find_by(id: @task.originating_conversation_id)
    return if conversation.blank? || !ConversationPolicy.new(@user_context, conversation).show?

    { id: conversation.id, display_id: conversation.display_id, account_id: account.id }
  end
end
