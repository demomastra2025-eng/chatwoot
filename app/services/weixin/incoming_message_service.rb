class Weixin::IncomingMessageService
  pattr_initialize [:channel!, :payload!]

  def perform
    return if external_message_id.blank? || sender_id.blank?
    return if inbox.messages.exists?(source_id: external_message_id)

    channel.remember_context_token!(chat_id, context_token) if context_token.present?
    Message.create!(message_attributes)
  rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid => e
    raise unless duplicate_message_error?(e)

    inbox.messages.find_by(source_id: external_message_id)
  end

  private

  delegate :account, :inbox, to: :channel

  def message_attributes
    {
      account: account,
      inbox: inbox,
      conversation: conversation,
      message_type: :incoming,
      content: message_content,
      source_id: external_message_id,
      sender: contact,
      content_attributes: {
        weixin: payload.slice(:chat_id, :sender_id, :recipient_id, :message_type).compact
      }
    }
  end

  def conversation
    @conversation ||= begin
      existing = contact_inbox.conversations.last
      if existing
        update_conversation_context!(existing)
        existing
      else
        Conversation.create!(
          account: account,
          inbox: inbox,
          contact: contact,
          contact_inbox: contact_inbox,
          additional_attributes: conversation_attributes
        )
      end
    end
  end

  def update_conversation_context!(conversation)
    conversation.update!(additional_attributes: conversation.additional_attributes.merge(conversation_attributes))
  end

  def conversation_attributes
    {
      'weixin_chat_id' => chat_id
    }.compact
  end

  def contact_inbox
    @contact_inbox ||= inbox.contact_inboxes.find_by(source_id: sender_id) || create_contact_inbox!
  end

  def create_contact_inbox!
    ContactInbox.create!(
      contact: contact,
      inbox: inbox,
      source_id: sender_id
    )
  end

  def contact
    @contact ||= begin
      existing_contact = contact_inbox&.contact if defined?(@contact_inbox) && @contact_inbox.present?
      existing_contact || account.contacts.create!(name: sender_name, additional_attributes: contact_attributes)
    end
  end

  def contact_attributes
    {
      'weixin' => {
        'sender_id' => sender_id,
        'avatar_url' => payload[:avatar_url]
      }.compact
    }
  end

  def duplicate_message_error?(error)
    error.message.to_s.include?('source_id') || inbox.messages.exists?(source_id: external_message_id)
  end

  def external_message_id
    @external_message_id ||= payload[:message_id].presence || payload[:id].presence
  end

  def sender_id
    @sender_id ||= payload[:sender_id].presence || payload[:peer_user_id].presence || payload[:from_user_id].presence || payload[:chat_id].presence
  end

  def sender_name
    payload[:sender_name].presence || payload[:nickname].presence || sender_id
  end

  def chat_id
    payload[:chat_id].presence || sender_id
  end

  def context_token
    payload[:context_token].presence || channel.context_token
  end

  def message_content
    payload[:text].presence || payload.dig(:content, :text).presence || ''
  end
end
