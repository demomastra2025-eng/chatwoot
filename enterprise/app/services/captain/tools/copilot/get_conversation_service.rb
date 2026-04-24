class Captain::Tools::Copilot::GetConversationService < Captain::Tools::Copilot::BaseAccountTool
  def self.name
    'get_conversation'
  end

  description 'Get details of a conversation including messages and contact information'

  param :conversation_id, type: :integer, desc: 'ID of the conversation to retrieve', required: true

  def execute(conversation_id:)
    conversation = permissible_conversations.includes(:contact, :assignee, :inbox, messages: :sender).find_by(display_id: conversation_id)
    return 'Conversation not found' if conversation.blank?

    formatted_payload(conversation: conversation_payload(conversation))
  end

  def active?
    user_has_permission('conversation_manage') ||
      user_has_permission('conversation_unassigned_manage') ||
      user_has_permission('conversation_participating_manage')
  end

  private

  def permissible_conversations
    Conversations::PermissionFilterService.new(account.conversations, @user, account).perform
  end

  def conversation_payload(conversation)
    {
      id: conversation.id,
      display_id: conversation.display_id,
      status: conversation.status,
      priority: conversation.priority,
      inbox_id: conversation.inbox_id,
      inbox_name: conversation.inbox&.name,
      contact_id: conversation.contact_id,
      contact_name: conversation.contact&.name,
      assignee_id: conversation.assignee_id,
      assignee_name: conversation.assignee&.name,
      team_id: conversation.team_id,
      labels: conversation.label_list.to_a,
      waiting_since: conversation.waiting_since&.iso8601,
      last_activity_at: conversation.last_activity_at&.iso8601,
      created_at: conversation.created_at&.iso8601,
      updated_at: conversation.updated_at&.iso8601,
      messages: conversation.messages.order(:created_at, :id).map { |message| message_payload(message) }
    }
  end

  def message_payload(message)
    {
      id: message.id,
      message_type: message.message_type,
      content_type: message.content_type,
      content: message.content,
      private: message.private,
      sender_type: message.sender_type,
      sender_id: message.sender_id,
      sender_name: message.sender&.try(:name),
      created_at: message.created_at&.iso8601
    }
  end
end
