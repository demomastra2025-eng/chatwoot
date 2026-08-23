class TelegramPersonal::UpdateMessageReadStatusService
  pattr_initialize [:inbox!, :params!]

  def perform
    return if chat_id.blank? || max_id.blank?

    contact_inbox = inbox.contact_inboxes.find_by(source_id: chat_id)
    return if contact_inbox.blank?

    outgoing_messages(contact_inbox).find_each do |message|
      Messages::StatusUpdateService.new(message, 'read').perform
    end
  end

  private

  def outgoing_messages(contact_inbox)
    Message.outgoing
           .where(account_id: inbox.account_id, inbox_id: inbox.id)
           .where(conversation_id: contact_inbox.conversations.select(:id))
           .where.not(status: :read)
           .where(
             <<~SQL.squish,
               CASE
                 WHEN messages.source_id ~ '^[0-9]+$' THEN messages.source_id::numeric <= :max_id
                 ELSE FALSE
               END
             SQL
             max_id: max_id
           )
  end

  def chat_id
    params[:chat_id].to_s.presence || params[:peer_user_id].to_s.presence
  end

  def max_id
    value = params[:max_id].to_i
    value.positive? ? value : nil
  end
end
