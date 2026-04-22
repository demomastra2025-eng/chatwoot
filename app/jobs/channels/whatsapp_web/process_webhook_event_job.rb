class Channels::WhatsappWeb::ProcessWebhookEventJob < MutexApplicationJob
  MESSAGE_EVENT_NAMES = %w[
    call
    messages.delete
    messages.edited
    messages.update
    messages.upsert
    send.message
    send.message.update
  ].freeze
  LOCK_TIMEOUT = 30.seconds

  queue_as :whatsappweb_inbound

  retry_on LockAcquisitionError, wait: 1.second, attempts: 15
  retry_on ActiveRecord::ConnectionTimeoutError, wait: 3.seconds, attempts: 10
  retry_on ActiveRecord::Deadlocked, wait: 2.seconds, attempts: 8

  def perform(channel_id, payload)
    channel = Channel::WhatsappWeb.find_by(id: channel_id)
    return if channel.blank?
    return if channel.inbox&.deleting?

    normalized_payload = payload.deep_symbolize_keys
    lock_key = message_lock_key(channel_id, normalized_payload)

    if lock_key.present?
      with_lock(lock_key, LOCK_TIMEOUT) { process_payload(channel, normalized_payload) }
    else
      process_payload(channel, normalized_payload)
    end
  rescue StandardError => e
    Rails.logger.error("[WHATSAPP WEB] Async webhook processing failed for channel #{channel_id}: #{e.message}")
    raise
  end

  private

  def process_payload(channel, payload)
    WhatsappWeb::IncomingEventService.new(
      channel: channel,
      payload: payload
    ).perform
  end

  def message_lock_key(channel_id, payload)
    source_id = lock_source_id(payload)
    return format(::Redis::Alfred::WHATSAPP_WEB_MESSAGE_EVENT_MUTEX, channel_id: channel_id, source_id: source_id) if source_id.present?

    remote_jid = lock_remote_jid(payload)
    return if remote_jid.blank?

    format(::Redis::Alfred::WHATSAPP_WEB_EVENT_MUTEX, channel_id: channel_id, remote_jid: remote_jid)
  end

  def lock_source_id(payload)
    return if payload.blank?
    return unless MESSAGE_EVENT_NAMES.include?(payload[:event].to_s)

    source_ids = extract_source_ids(payload).uniq
    return if source_ids.blank? || source_ids.many?

    source_ids.first
  end

  def lock_remote_jid(payload)
    return if payload.blank?
    return unless MESSAGE_EVENT_NAMES.include?(payload[:event].to_s)

    remote_jids = extract_remote_jids(payload).uniq
    return if remote_jids.blank? || remote_jids.many?

    remote_jids.first
  end

  def extract_remote_jids(payload)
    case payload[:event].to_s
    when 'messages.update'
      update_remote_jids(payload[:data])
    when 'call'
      call_remote_jids(payload[:data])
    else
      key_remote_jids(payload[:data])
    end
  end

  def extract_source_ids(payload)
    case payload[:event].to_s
    when 'messages.update'
      update_source_ids(payload[:data])
    when 'call'
      []
    else
      key_source_ids(payload[:data])
    end
  end

  def update_remote_jids(data)
    Array.wrap(data).filter_map do |entry|
      normalized_entry = WhatsappWeb::ProviderPayloadNormalizer.normalize_message_update(entry)
      normalized_entry&.dig(:key, :remoteJid).presence
    end
  end

  def update_source_ids(data)
    Array.wrap(data).filter_map do |entry|
      normalized_entry = WhatsappWeb::ProviderPayloadNormalizer.normalize_message_update(entry)
      normalized_entry&.dig(:key, :id).presence
    end
  end

  def call_remote_jids(data)
    [
      WhatsappWeb::ProviderPayloadNormalizer.canonical_remote_jid(
        data.to_h[:from],
        data.to_h[:to],
        data.to_h[:chatId]
      ).presence
    ].compact
  end

  def key_remote_jids(data)
    key = data.to_h[:key].to_h.deep_symbolize_keys

    [
      WhatsappWeb::ProviderPayloadNormalizer.canonical_remote_jid(
        key[:remoteJid],
        key[:remoteJidAlt],
        key[:remoteLid]
      ).presence
    ].compact
  end

  def key_source_ids(data)
    key = data.to_h[:key].to_h.deep_symbolize_keys

    [key[:id].presence].compact
  end
end
