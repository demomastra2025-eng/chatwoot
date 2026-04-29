class Channels::WhatsappWeb::MessageUpdateBackfillJob < ApplicationJob
  MAX_ATTEMPTS = 3
  RETRY_DELAY = 3.seconds

  queue_as :whatsappweb_echo

  retry_on ActiveRecord::ConnectionTimeoutError, wait: 3.seconds, attempts: 10
  retry_on ActiveRecord::Deadlocked, wait: 2.seconds, attempts: 8

  def perform(channel_id, payload = {}, attempt_number = 1)
    channel = processable_channel(channel_id)
    return if channel.blank?

    normalized_payload = normalized_update_payload(payload)
    return if normalized_payload.blank?

    backfill_message_update(channel, normalized_payload, attempt_number.to_i)
  rescue StandardError => e
    Rails.logger.error(
      "[WHATSAPP WEB] Message update backfill failed for channel #{channel_id}: #{e.class}: #{e.message}"
    )
    raise
  end

  private

  def processable_channel(channel_id)
    channel = Channel::WhatsappWeb.find_by(id: channel_id)
    return if channel.blank? || channel.inbox.blank?
    return unless channel.account.active?

    channel
  end

  def normalized_update_payload(payload)
    normalized_payload = WhatsappWeb::ProviderPayloadNormalizer.normalize_message_update(payload)&.deep_stringify_keys
    return if normalized_payload.blank?

    source_id(normalized_payload).present? ? normalized_payload : nil
  end

  def backfill_message_update(channel, payload, attempt_number)
    message = existing_message(channel, payload)
    return apply_status!(message, payload) if message.present?

    provider_message = fetch_provider_message(channel, payload, attempt_number)
    return if provider_message == :stopped

    import_provider_message!(channel, provider_message) if provider_message.present?

    message = existing_message(channel, payload)
    return apply_status!(message, payload) if message.present?

    retry_or_log_exhausted(channel, payload, attempt_number)
  end

  def existing_message(channel, payload)
    Message.find_by(source_id: source_id(payload), inbox_id: channel.inbox.id)
  end

  def source_id(payload)
    payload.dig('key', 'id').to_s
  end

  def fetch_provider_message(channel, payload, attempt_number)
    channel.provider_service.fetch_message_by_source_id(
      source_id: source_id(payload),
      remote_jid: WhatsappWeb::ProviderPayloadNormalizer.provider_lookup_remote_jid(payload.dig('key', 'remoteJid')),
      from_me: true
    )
  rescue WhatsappWeb::Providers::EvolutionService::RequestError => e
    handle_provider_request_error(channel, payload, attempt_number, e)
  end

  def import_provider_message!(channel, provider_message)
    WhatsappWeb::IncomingMessageService.new(
      inbox: channel.inbox,
      params: provider_message.deep_symbolize_keys,
      outgoing_echo: true
    ).perform
  end

  def handle_provider_request_error(channel, payload, attempt_number, error)
    if error.retryable? && attempt_number < MAX_ATTEMPTS
      self.class.set(wait: RETRY_DELAY).perform_later(channel.id, payload, attempt_number + 1)
      return :stopped
    end

    reason = error.provider_validation_error? ? 'provider validation error' : "provider status #{error.status}"
    Rails.logger.warn(
      "[WHATSAPP WEB] messages.update backfill stopped after #{reason} for channel=#{channel.id} " \
      "source_id=#{source_id(payload)} remote_jid=#{payload.dig('key', 'remoteJid')}"
    )
    :stopped
  end

  def retry_or_log_exhausted(channel, payload, attempt_number)
    if attempt_number < MAX_ATTEMPTS
      self.class.set(wait: RETRY_DELAY).perform_later(channel.id, payload, attempt_number + 1)
      return
    end

    Rails.logger.warn(
      "[WHATSAPP WEB] messages.update backfill exhausted for channel=#{channel.id} " \
      "source_id=#{source_id(payload)} remote_jid=#{payload.dig('key', 'remoteJid')}"
    )
  end

  def apply_status!(message, payload)
    WhatsappWeb::ProviderPayloadNormalizer.apply_message_status!(message, payload.dig('update', 'status'))
  end
end
