class TelegramPersonal::UpdateMessageReadStatusService
  pattr_initialize [:inbox!, :params!]

  def perform
    return if chat_id.blank? || max_id.blank?

    contact_inbox = inbox.contact_inboxes.find_by(source_id: chat_id)
    return if contact_inbox.blank?

    contact_inbox.conversations.includes(:messages).find_each do |conversation|
      outgoing_messages(conversation).each do |message|
        Messages::StatusUpdateService.new(message, 'read').perform
      end
    end
  end

  private

  def outgoing_messages(conversation)
    conversation.messages.outgoing.reject do |message|
      source_id = message.source_id.to_s
      source_id.blank? || !source_id.match?(/\A\d+\z/) || source_id.to_i > max_id
    end
  end

  def chat_id
    params[:chat_id].to_s.presence || params[:peer_user_id].to_s.presence
  end

  def max_id
    value = params[:max_id].to_i
    value.positive? ? value : nil
  end
end
