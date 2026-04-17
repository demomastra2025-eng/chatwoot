class Channels::WhatsappWeb::MessageUpdateBackfillJob < ApplicationJob
  MAX_ATTEMPTS = 3
  RETRY_DELAY = 3.seconds

  queue_as :whatsappweb_echo

  retry_on ActiveRecord::ConnectionTimeoutError, wait: 3.seconds, attempts: 10
  retry_on ActiveRecord::Deadlocked, wait: 2.seconds, attempts: 8

  def perform(channel_id, payload = {}, attempt_number = 1)
    channel = Channel::WhatsappWeb.find_by(id: channel_id)
    return if channel.blank? || channel.inbox.blank?
    return unless channel.account.active?

    payload = WhatsappWeb::ProviderPayloadNormalizer.normalize_message_update(payload)&.deep_stringify_keys
    return if payload.blank?

    source_id = payload.dig('key', 'id').to_s
    return if source_id.blank?

    message = Message.find_by(source_id: source_id, inbox_id: channel.inbox.id)
    return apply_status!(message, payload) if message.present?

    provider_message = channel.provider_service.fetch_message_by_source_id(
      source_id: source_id,
      remote_jid: WhatsappWeb::ProviderPayloadNormalizer.provider_lookup_remote_jid(payload.dig('key', 'remoteJid')),
      from_me: true
    )

    if provider_message.present?
      WhatsappWeb::IncomingMessageService.new(
        inbox: channel.inbox,
        params: provider_message.deep_symbolize_keys,
        outgoing_echo: true
      ).perform

      message = Message.find_by(source_id: source_id, inbox_id: channel.inbox.id)
      return apply_status!(message, payload) if message.present?
    end

    if attempt_number < MAX_ATTEMPTS
      self.class.set(wait: RETRY_DELAY).perform_later(channel.id, payload, attempt_number + 1)
      return
    end

    Rails.logger.warn(
      "[WHATSAPP WEB] messages.update backfill exhausted for channel=#{channel.id} " \
      "source_id=#{source_id} remote_jid=#{payload.dig('key', 'remoteJid')}"
    )
  rescue StandardError => e
    Rails.logger.error(
      "[WHATSAPP WEB] Message update backfill failed for channel #{channel_id}: #{e.class}: #{e.message}"
    )
    raise
  end

  private

  def apply_status!(message, payload)
    WhatsappWeb::ProviderPayloadNormalizer.apply_message_status!(message, payload.dig('update', 'status'))
  end
end
