class TelegramPersonal::EnrichHistoryMediaService
  class Error < TelegramPersonal::GatewayClient::GatewayError; end

  pattr_initialize [:message!]

  def perform
    raise ArgumentError, 'Message does not belong to a Telegram Personal inbox' unless channel.is_a?(Channel::TelegramPersonal)

    message.reload
    identity = Messages::HistoryMediaIdentity.new(message)
    identity.verify!(message)
    return message unless incomplete_history_media?

    context = TelegramPersonal::IncomingMessageService.history_media_context_for(message)
    Current.with_runtime_events_suppressed do
      payload = fetch_enriched_payload!
      reconcile_enriched_payload!(payload, context, identity)
    end
    identity.verify!(message)
  rescue Messages::HistoryMediaIdentity::Changed
    raise Error, 'history_media_unavailable'
  end

  private

  def fetch_enriched_payload!
    result = TelegramPersonal::GatewayClient.new(channel: channel).enrich_message_media!(
      chat_id: chat_id,
      peer_user_id: peer_user_id,
      message_id: raw_message_id,
      telegram_message_ids: telegram_message_ids
    )
    payload = result.with_indifferent_access[:payload]
    raise TelegramPersonal::GatewayClient::GatewayError, 'Telegram Personal gateway returned an empty media payload' if payload.blank?

    payload
  end

  def reconcile_enriched_payload!(payload, context, identity)
    TelegramPersonal::IncomingMessageService.new(
      inbox: inbox,
      history_media_context: context,
      history_media_identity: identity,
      params: payload.to_h.deep_symbolize_keys.merge(imported_history: true, history_media_incomplete: false)
    ).perform
  end

  def inbox
    message.inbox
  end

  def channel
    inbox&.channel
  end

  def conversation
    message.conversation
  end

  def incomplete_history_media?
    ActiveModel::Type::Boolean.new.cast(message.content_attributes.to_h['telegram_history_media_incomplete']) == true
  end

  def contact_source_id
    conversation&.contact_inbox&.source_id.to_s.presence
  end

  def chat_id
    conversation&.additional_attributes.to_h['chat_id'].to_s.presence || contact_source_id
  end

  def peer_user_id
    conversation&.additional_attributes.to_h['peer_user_id'].to_s.presence || contact_source_id
  end

  def raw_message_id
    skipped_message_ids.first || TelegramPersonal::MessageSourceId.provider_id(message.source_id)
  end

  def telegram_message_ids
    return [] if all_telegram_message_ids.blank?

    skipped_message_ids.presence || all_telegram_message_ids
  end

  def skipped_message_ids
    Array.wrap(message.content_attributes.to_h['telegram_history_media_skipped_message_ids'])
         .map { |id| TelegramPersonal::MessageSourceId.provider_id(id) }
         .reject(&:blank?)
         .uniq
  end

  def all_telegram_message_ids
    Array.wrap(message.content_attributes.to_h['telegram_message_ids'])
         .map { |id| TelegramPersonal::MessageSourceId.provider_id(id) }
         .reject(&:blank?)
         .uniq
  end
end
