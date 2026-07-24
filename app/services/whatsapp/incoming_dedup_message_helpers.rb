module Whatsapp::IncomingDedupMessageHelpers
  def find_message_by_source_id(source_id)
    return unless source_id

    @message = inbox.messages.find_by(source_id: source_id.to_s)
  end

  def lock_message_source_id!
    message_dedup_lock&.acquire!
  end

  private

  def message_dedup_lock
    return if messages_data.blank?

    @message_dedup_lock ||= Whatsapp::MessageDedupLock.new(inbox_id: inbox.id, source_id: messages_data.first[:id])
  end
end
