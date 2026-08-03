class Captain::Tools::Copilot::GetConversationService < Captain::Tools::Copilot::BaseAccountTool
  DEFAULT_MESSAGE_LIMIT = 20
  MAX_MESSAGE_LIMIT = 50

  def self.name
    'get_conversation'
  end

  description 'Get details of a conversation including messages and contact information'

  param :conversation_id, type: :integer, desc: 'ID of the conversation to retrieve', required: true
  param :message_limit, type: :integer, desc: 'Maximum number of latest public messages to return (default 20, max 50)', required: false
  param :include_private, type: :boolean, desc: 'Include private notes. Restricted to account administrators', required: false

  def execute(conversation_id:, message_limit: DEFAULT_MESSAGE_LIMIT, include_private: false)
    include_private = cast_boolean(include_private)
    return tool_failure('Account administrator permission is required to include private notes') if include_private && !account_administrator?

    conversation = permissible_conversations.includes(:contact, :assignee, :inbox).find_by(display_id: conversation_id)
    return tool_failure('Conversation not found') if conversation.blank?

    limit = parse_limit(message_limit, default: DEFAULT_MESSAGE_LIMIT, max: MAX_MESSAGE_LIMIT)
    formatted_payload(conversation: conversation_payload(conversation, message_limit: limit, include_private: include_private))
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

  def conversation_payload(conversation, message_limit:, include_private:)
    messages, messages_truncated = message_window(conversation, message_limit: message_limit, include_private: include_private)

    base_conversation_payload(conversation).merge(
      messages: messages.map { |message| message_payload(message) },
      message_window: message_window_payload(
        message_limit: message_limit,
        messages: messages,
        messages_truncated: messages_truncated,
        include_private: include_private
      )
    )
  end

  def base_conversation_payload(conversation)
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
      labels: conversation.label_list.to_a
    }.merge(conversation_timestamps(conversation))
  end

  def conversation_timestamps(conversation)
    {
      waiting_since: conversation.waiting_since&.iso8601,
      last_activity_at: conversation.last_activity_at&.iso8601,
      created_at: conversation.created_at&.iso8601,
      updated_at: conversation.updated_at&.iso8601
    }
  end

  def message_window_payload(message_limit:, messages:, messages_truncated:, include_private:)
    {
      limit: message_limit,
      returned_count: messages.size,
      truncated: messages_truncated,
      private_messages_included: include_private
    }
  end

  def message_window(conversation, message_limit:, include_private:)
    scope = conversation.messages.includes(:sender)
    scope = scope.where(private: false) unless include_private
    recent_messages = scope.reorder(created_at: :desc, id: :desc).limit(message_limit + 1).to_a

    [recent_messages.first(message_limit).reverse, recent_messages.size > message_limit]
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
