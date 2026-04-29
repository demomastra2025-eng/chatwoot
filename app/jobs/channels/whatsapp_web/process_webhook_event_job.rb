require 'digest'

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
  IN_FLIGHT_DEDUP_TTL = 2.minutes.to_i

  queue_as :whatsappweb_inbound

  retry_on LockAcquisitionError, wait: 1.second, attempts: 15
  retry_on ActiveRecord::ConnectionTimeoutError, wait: 3.seconds, attempts: 10
  retry_on ActiveRecord::Deadlocked, wait: 2.seconds, attempts: 8

  def perform(channel_id, payload)
    channel = processable_channel(channel_id)
    return if channel.blank?

    normalized_payload = payload.deep_symbolize_keys
    dedup_key = in_flight_dedup_key(channel_id, normalized_payload)
    dedup_claimed = claim_event_in_flight!(dedup_key)
    return if duplicate_in_flight_event?(dedup_key, dedup_claimed)

    process_with_lock(channel, normalized_payload)
  rescue LockAcquisitionError => e
    Rails.logger.info("[WHATSAPP WEB] Webhook processing deferred for channel #{channel_id}: #{e.message}")
    raise
  rescue StandardError => e
    Rails.logger.error("[WHATSAPP WEB] Async webhook processing failed for channel #{channel_id}: #{e.message}")
    raise
  ensure
    release_event_in_flight!(dedup_key) if dedup_claimed
  end

  private

  def processable_channel(channel_id)
    channel = Channel::WhatsappWeb.find_by(id: channel_id)
    return if channel.blank? || channel.inbox&.deleting?

    channel
  end

  def process_with_lock(channel, payload)
    lock_key = message_lock_key(channel.id, payload)

    if lock_key.present?
      with_lock(lock_key, LOCK_TIMEOUT) { process_payload(channel, payload) }
    else
      process_payload(channel, payload)
    end
  end

  def process_payload(channel, payload)
    WhatsappWeb::IncomingEventService.new(
      channel: channel,
      payload: payload
    ).perform
  end

  def claim_event_in_flight!(dedup_key)
    return false if dedup_key.blank?

    claimed = Redis::Alfred.set(dedup_key, true, nx: true, ex: IN_FLIGHT_DEDUP_TTL)
    return true if claimed.present?

    Rails.logger.info("[WHATSAPP WEB] Skipping duplicate in-flight webhook event #{dedup_key}")
    false
  end

  def duplicate_in_flight_event?(dedup_key, dedup_claimed)
    dedup_key.present? && !dedup_claimed
  end

  def release_event_in_flight!(dedup_key)
    Redis::Alfred.delete(dedup_key) if dedup_key.present?
  end

  def in_flight_dedup_key(channel_id, payload)
    return if payload.blank?
    return unless MESSAGE_EVENT_NAMES.include?(payload[:event].to_s)

    fingerprint = Digest::SHA256.hexdigest(JSON.generate(canonical_json_value(payload)))
    format(::Redis::Alfred::WHATSAPP_WEB_EVENT_IN_FLIGHT, channel_id: channel_id, fingerprint: fingerprint)
  end

  def canonical_json_value(value)
    case value
    when Hash
      value.deep_stringify_keys.sort.to_h.transform_values { |nested_value| canonical_json_value(nested_value) }
    when Array
      value.map { |nested_value| canonical_json_value(nested_value) }
    else
      value
    end
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

  def handle_failed_lock_acquisition(lock_key)
    Rails.logger.info "[#{self.class.name}] Lock busy on attempt #{executions}: #{lock_key}"
    raise LockAcquisitionError, "Failed to acquire lock for key: #{lock_key}"
  end
end
