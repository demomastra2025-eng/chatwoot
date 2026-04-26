class Channels::WhatsappWeb::MediaAttachmentBackfillJob < ApplicationJob
  MAX_ATTEMPTS = 3
  RETRY_DELAY = 30.seconds

  queue_as :whatsappweb_history

  retry_on ActiveRecord::ConnectionTimeoutError, wait: 3.seconds, attempts: 10
  retry_on ActiveRecord::Deadlocked, wait: 2.seconds, attempts: 8

  def perform(channel_id, source_id, record_payload = {}, attempt_number = 1)
    channel = eligible_channel(channel_id)
    return if channel.blank?

    message = Message.find_by(source_id: source_id.to_s, inbox_id: channel.inbox.id)
    return retry_later(channel, source_id, record_payload, attempt_number) if message.blank?
    return if message.attachments.any?

    record = provider_media_record(channel, source_id.to_s, record_payload, outgoing: message.outgoing?)
    attachment_payload = extract_attachment_payload(record)
    return retry_later(channel, source_id, record_payload, attempt_number) if attachment_payload.blank?

    attach_or_retry(
      channel: channel,
      message: message,
      attachment_payload: attachment_payload,
      record: record,
      source_id: source_id,
      record_payload: record_payload,
      attempt_number: attempt_number
    )
  end

  private

  def eligible_channel(channel_id)
    channel = Channel::WhatsappWeb.find_by(id: channel_id)
    return if channel.blank? || channel.inbox.blank?
    return unless channel.account.active?

    channel
  end

  def attach_or_retry(context)
    provider_payload = fetch_provider_media(context[:channel], context[:record], context[:source_id])
    if provider_attachment_available?(provider_payload)
      return attach_provider_media!(context[:message], context[:attachment_payload], provider_payload)
    end
    return if provider_attachment_unavailable?(provider_payload)

    retry_later(context[:channel], context[:source_id], context[:record_payload], context[:attempt_number])
  end

  def provider_media_record(channel, source_id, record_payload, outgoing:)
    record = record_payload.to_h
    return record if extract_attachment_payload(record).present?

    refetch_provider_message(channel, source_id, record, outgoing: outgoing) || record
  end

  def refetch_provider_message(channel, source_id, record, outgoing:)
    key = record.to_h.deep_symbolize_keys[:key].to_h.deep_symbolize_keys
    channel.provider_service.fetch_message_by_source_id(
      source_id: source_id,
      remote_jid: WhatsappWeb::ProviderPayloadNormalizer.provider_lookup_remote_jid(key[:remoteJid]),
      from_me: outgoing
    )
  rescue StandardError => e
    Rails.logger.info("[WHATSAPP WEB] Media attachment provider message lookup failed for #{source_id}: #{e.message}")
    nil
  end

  def fetch_provider_media(channel, record, source_id)
    channel.provider_service.fetch_message_media(record: record)
  rescue StandardError => e
    Rails.logger.info("[WHATSAPP WEB] Media attachment provider fetch failed for #{source_id}: #{e.message}")
    nil
  end

  def attach_provider_media!(message, attachment_payload, provider_payload)
    provider_payload = provider_payload.to_h.deep_symbolize_keys
    return if message.attachments.reload.any?

    attachment_payload[:file_name] = provider_payload[:fileName].presence || attachment_payload[:file_name]
    attachment_payload[:mimetype] = provider_payload[:mimetype].presence || attachment_payload[:mimetype]
    file = file_from_provider_payload(provider_payload, attachment_payload)

    attachment = message.attachments.new(
      account_id: message.account_id,
      file_type: attachment_payload[:file_type],
      file: {
        io: file,
        filename: file.original_filename,
        content_type: file.content_type
      }
    )
    attachment.skip_storage_limit_validation!
    attachment.save!
  end

  def file_from_provider_payload(provider_payload, attachment_payload)
    tempfile = Tempfile.new(['whatsapp-web-media-backfill', File.extname(attachment_payload[:file_name].to_s)])
    tempfile.binmode
    tempfile.write(Base64.decode64(provider_payload[:base64]))
    tempfile.rewind
    tempfile.define_singleton_method(:original_filename) { attachment_payload[:file_name] }
    tempfile.define_singleton_method(:content_type) { attachment_payload[:mimetype] }
    tempfile
  end

  def retry_later(channel, source_id, record_payload, attempt_number)
    if attempt_number.to_i < MAX_ATTEMPTS
      self.class.set(wait: RETRY_DELAY).perform_later(channel.id, source_id.to_s, record_payload.to_h.deep_stringify_keys, attempt_number.to_i + 1)
      return
    end

    Rails.logger.warn(
      "[WHATSAPP WEB] Media attachment backfill exhausted for channel=#{channel.id} source_id=#{source_id}"
    )
  end

  def extract_attachment_payload(record)
    message = record.to_h.deep_symbolize_keys[:message].to_h.deep_symbolize_keys

    {
      imageMessage: :image,
      videoMessage: :video,
      audioMessage: :audio,
      documentMessage: :file,
      stickerMessage: :image
    }.each do |key, file_type|
      payload = media_message_payload(message, key)
      next if payload.blank?

      attachment = payload.to_h.deep_symbolize_keys
      return {
        file_type: file_type,
        file_name: attachment[:fileName] || attachment[:name] || "whatsapp-web-#{SecureRandom.hex(8)}",
        mimetype: attachment[:mimetype] || 'application/octet-stream'
      }
    end

    {}
  end

  def media_message_payload(message, key)
    direct_payload = message[key]
    return direct_payload if direct_payload.present?
    return unless key == :documentMessage

    message.dig(:documentWithCaptionMessage, :message, :documentMessage)
  end

  def provider_attachment_available?(provider_payload)
    provider_payload = provider_payload.to_h.deep_symbolize_keys
    provider_payload.present? &&
      provider_payload[:unavailable] != true &&
      provider_payload[:base64].present?
  end

  def provider_attachment_unavailable?(provider_payload)
    provider_payload.to_h.deep_symbolize_keys[:unavailable] == true
  end
end
