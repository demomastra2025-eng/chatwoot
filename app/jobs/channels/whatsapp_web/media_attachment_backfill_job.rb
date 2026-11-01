class Channels::WhatsappWeb::MediaAttachmentBackfillJob < ApplicationJob
  MAX_ATTEMPTS = 3
  RETRY_DELAY = 30.seconds

  queue_as :whatsappweb_history

  retry_on ActiveRecord::ConnectionTimeoutError, wait: 3.seconds, attempts: 10
  retry_on ActiveRecord::Deadlocked, wait: 2.seconds, attempts: 8

  def perform(channel_id, source_id, record_payload = {}, attempt_number = 1)
    return if source_id.blank?

    channel = eligible_channel(channel_id)
    return if channel.blank?

    message = Message.find_by(source_id: source_id.to_s, inbox_id: channel.inbox.id)
    return retry_later(channel, source_id, record_payload, attempt_number) if message.blank?
    return if message.attachments.any?

    record = provider_media_record(channel, source_id.to_s, record_payload, outgoing: message.outgoing?)
    attachment_payload = extract_attachment_payload(record)
    return retry_later(channel, source_id, record_payload, attempt_number) if attachment_payload.blank?

    attach_or_retry(
      channel: channel, message: message, attachment_payload: attachment_payload,
      record: record, source_id: source_id, record_payload: record_payload, attempt_number: attempt_number
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
    provider_payload, active_record = resolve_provider_media(context)
    if provider_attachment_available?(provider_payload)
      return attach_provider_media!(context[:message], extract_attachment_payload(active_record), provider_payload)
    end

    decrypted_file, file_type, attempted_decryption = decrypt_backfill_media(context)
    return save_backfill_attachment!(context[:message], file_type, decrypted_file) if decrypted_file.present?
    return if provider_attachment_unavailable?(provider_payload) && !attempted_decryption

    retry_later(context[:channel], context[:source_id], context[:record_payload], context[:attempt_number])
  end

  def resolve_provider_media(context)
    payload = fetch_provider_media(context[:channel], context[:record], context[:source_id])
    return [payload, context[:record]] if provider_attachment_available?(payload)
    return [payload, context[:record]] if provider_attachment_unavailable?(payload) && complete_record_encryption_metadata?(context[:record])

    refetched = memoized_refetched_record(context)
    return [payload, context[:record]] if refetched.blank?
    return [payload, context[:record]] if provider_attachment_unavailable?(payload) && !refetched_remote_jid_changed?(context[:record], refetched)

    [fetch_provider_media(context[:channel], refetched, context[:source_id]), refetched]
  end

  def complete_record_encryption_metadata?(record)
    meta = WhatsappWeb::MediaDecryptor.extract_encryption_metadata(record: record)
    meta[:url].present? && meta[:media_key].present?
  end

  def refetched_remote_jid_changed?(initial_record, refetched)
    initial_jid = initial_record.to_h.deep_symbolize_keys.dig(:key, :remoteJid).to_s
    refetched_jid = refetched.to_h.deep_symbolize_keys.dig(:key, :remoteJid).to_s
    refetched_jid.present? && refetched_jid != initial_jid
  end

  def decrypt_backfill_media(context)
    meta = backfill_encryption_metadata(context)
    return [nil, nil, false] if meta[:url].blank? || meta[:media_key].blank?

    file_type = WhatsappWeb::MediaMimeNormalizer.file_type_for(media_kind: meta[:media_kind], mime_type: meta[:mime_type]).to_sym
    file = WhatsappWeb::MediaDecryptor.decrypt_remote_media(url: meta[:url], media_key: meta[:media_key], metadata: meta)
    [file, file_type, true]
  rescue WhatsappWeb::MediaDecryptor::DecryptionError, Down::Error => e
    Rails.logger.warn("[WHATSAPP WEB] Backfill native media decryption failed for #{context[:source_id]}: #{e.class}: #{e.message}")
    [nil, nil, true]
  end

  def backfill_encryption_metadata(context)
    raw_meta = WhatsappWeb::MediaDecryptor.extract_encryption_metadata(record: context[:record])
    return raw_meta if raw_meta[:url].present? && raw_meta[:media_key].present?

    refetched = memoized_refetched_record(context)
    return raw_meta if refetched.blank?

    WhatsappWeb::MediaDecryptor.merge_encryption_metadata(
      raw_meta,
      WhatsappWeb::MediaDecryptor.extract_encryption_metadata(record: refetched)
    )
  end

  def memoized_refetched_record(context)
    return context[:refetched_record] if context.key?(:refetched_record)

    context[:refetched_record] = refetch_provider_message(
      context[:channel], context[:source_id].to_s, context[:record], outgoing: context[:message].outgoing?
    )
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
    payload = provider_payload.to_h.deep_symbolize_keys
    media_kind = attachment_payload[:media_kind]
    raw_name = payload[:fileName].presence || attachment_payload[:raw_file_name] || attachment_payload[:file_name]
    raw_mime = payload[:mimetype].presence || attachment_payload[:raw_mimetype] || attachment_payload[:mimetype]
    attachment_payload[:mimetype] = WhatsappWeb::MediaMimeNormalizer.normalize_mime_type(raw_mime, filename: raw_name, media_kind: media_kind)
    attachment_payload[:file_name] = WhatsappWeb::MediaMimeNormalizer.sanitize_filename(
      raw_name, mime_type: attachment_payload[:mimetype], media_kind: media_kind
    )
    save_backfill_attachment!(message, attachment_payload[:file_type], file_from_provider_payload(payload, attachment_payload))
  end

  def save_backfill_attachment!(message, file_type, file)
    return if message.attachments.reload.any?

    attachment = message.attachments.new(
      account_id: message.account_id,
      file_type: file_type,
      file: { io: file, filename: file.original_filename, content_type: file.content_type }
    )
    attachment.skip_storage_limit_validation!
    attachment.save!
  ensure
    file.close! if file.respond_to?(:close!)
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

    Rails.logger.warn("[WHATSAPP WEB] Media attachment backfill exhausted for channel=#{channel.id} source_id=#{source_id}")
  end

  def extract_attachment_payload(record)
    node_info = WhatsappWeb::MediaMimeNormalizer.extract_media_node(record)
    return {} if node_info.blank?

    node = node_info[:node]
    media_kind = node_info[:media_kind]
    raw_name = node[:fileName] || node[:name]
    normalized_mime = WhatsappWeb::MediaMimeNormalizer.normalize_mime_type(node[:mimetype], filename: raw_name, media_kind: media_kind)

    {
      media_kind: media_kind, raw_file_name: raw_name, raw_mimetype: node[:mimetype],
      file_type: WhatsappWeb::MediaMimeNormalizer.file_type_for(media_kind: media_kind, mime_type: normalized_mime).to_sym,
      file_name: WhatsappWeb::MediaMimeNormalizer.sanitize_filename(raw_name, mime_type: normalized_mime, media_kind: media_kind),
      mimetype: normalized_mime
    }
  end

  def provider_attachment_available?(provider_payload)
    payload = provider_payload.to_h.deep_symbolize_keys
    payload.present? && payload[:unavailable] != true && payload[:base64].present?
  end

  def provider_attachment_unavailable?(provider_payload)
    provider_payload.to_h.deep_symbolize_keys[:unavailable] == true
  end
end
