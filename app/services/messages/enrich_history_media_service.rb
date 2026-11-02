class Messages::EnrichHistoryMediaService
  class Error < StandardError; end

  pattr_initialize [:message!]

  def perform
    raise Error, 'History media is unavailable' if unavailable_message?

    identity = Messages::HistoryMediaIdentity.new(message)
    identity.verify!(message)

    result = Current.with_runtime_events_suppressed { enrich_media }
    identity.verify!(result)
  rescue Messages::HistoryMediaIdentity::Changed
    raise Error, 'History media is unavailable'
  end

  private

  def enrich_media
    case message.inbox.channel
    when Channel::WhatsappWeb
      unless message.attachments.exists? || message.content_attributes.to_h.dig('history_attachment', 'unavailable') == true
        raise Error, 'History media is unavailable'
      end

      WhatsappWeb::EnrichHistoryMediaService.new(message: message).perform
    when Channel::TelegramPersonal
      TelegramPersonal::EnrichHistoryMediaService.new(message: message).perform
    else
      raise Error, 'History media is unavailable'
    end
  end

  def unavailable_message?
    message.inbox.blank? || message.inbox.deleting? || message.source_id.blank? ||
      message.content_attributes.to_h['deleted'].present? || !message.account.active? ||
      message.conversation.inbox_id != message.inbox_id
  end
end
