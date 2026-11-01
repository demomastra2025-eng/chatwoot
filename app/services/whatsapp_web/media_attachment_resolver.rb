class WhatsappWeb::MediaAttachmentResolver
  Result = Struct.new(:file, :pending_backfill, keyword_init: true)

  def initialize(channel:, record:, source_id:)
    @channel = channel
    @record = record.to_h.deep_symbolize_keys
    @source_id = source_id.to_s
    @provider_media_unavailable = false
    @transient_media_failure = false
  end

  def resolve(attachment_payload)
    payload = attachment_payload.to_h.deep_symbolize_keys
    resolved_file = file_from_base64(payload) ||
                    download_provider_attachment(payload) ||
                    decrypt_encrypted_attachment(payload) ||
                    download_remote_attachment(payload)
    return Result.new(file: resolved_file, pending_backfill: false) if resolved_file.present?

    Result.new(file: nil, pending_backfill: @transient_media_failure || !@provider_media_unavailable)
  end

  private

  attr_reader :channel, :record, :source_id

  def file_from_base64(attachment_payload)
    return if attachment_payload[:base64].blank?

    tempfile_from_base64(
      attachment_payload[:base64],
      filename: attachment_payload[:fileName] || attachment_payload[:filename],
      content_type: attachment_payload[:mimetype] || attachment_payload[:mime_type],
      media_kind: media_kind_for(attachment_payload)
    )
  end

  def download_provider_attachment(attachment_payload)
    provider_file = provider_file_from(record, attachment_payload)
    return provider_file if provider_file.present? || @provider_media_unavailable

    provider_file_from(refetched_provider_message, attachment_payload)
  end

  def decrypt_encrypted_attachment(attachment_payload)
    meta = encryption_metadata_for(attachment_payload)
    return if meta[:url].blank? || meta[:media_key].blank?

    WhatsappWeb::MediaDecryptor.decrypt_remote_media(url: meta[:url], media_key: meta[:media_key], metadata: meta)
  rescue WhatsappWeb::MediaDecryptor::DecryptionError, Down::Error => e
    @transient_media_failure = true
    Rails.logger.warn("[WHATSAPP WEB] Native media decryption failed for #{source_id}: #{e.class}: #{e.message}")
    nil
  end

  def download_remote_attachment(attachment_payload)
    media_url = attachment_payload[:mediaUrl] || attachment_payload[:url]
    return if media_url.blank? || encrypted_attachment_payload?(attachment_payload, media_url)

    downloaded = Down.download(media_url)
    reject_encrypted_download(downloaded)
  rescue Down::Error => e
    Rails.logger.warn("[WHATSAPP WEB] Skipping unavailable media attachment #{source_id}: #{e.message}")
    nil
  end

  def reject_encrypted_download(downloaded)
    return downloaded unless downloaded.respond_to?(:original_filename) && downloaded.original_filename.to_s.match?(/\.enc\z/i)

    downloaded.close! if downloaded.respond_to?(:close!)
    Rails.logger.warn("[WHATSAPP WEB] Blocked raw .enc remote attachment for #{source_id}")
    nil
  end

  def encrypted_attachment_payload?(attachment_payload, media_url)
    meta = WhatsappWeb::MediaDecryptor.extract_encryption_metadata(record: record, attachment_payload: attachment_payload)
    WhatsappWeb::MediaDecryptor.encrypted_media_payload?(
      url: media_url,
      media_key: meta[:media_key],
      filename: attachment_payload[:fileName] || attachment_payload[:filename]
    )
  end

  def encryption_metadata_for(attachment_payload)
    meta = WhatsappWeb::MediaDecryptor.extract_encryption_metadata(record: record, attachment_payload: attachment_payload)
    return meta if (meta[:url].present? && meta[:media_key].present?) || @provider_media_unavailable
    return meta if refetched_provider_message.blank?

    refetched_meta = WhatsappWeb::MediaDecryptor.extract_encryption_metadata(record: refetched_provider_message)
    merged = refetched_meta.compact_blank.merge(meta.compact_blank)
    if !WhatsappWeb::MediaMimeNormalizer.concrete_mime?(merged[:mime_type]) &&
       WhatsappWeb::MediaMimeNormalizer.concrete_mime?(refetched_meta[:mime_type])
      merged[:mime_type] = refetched_meta[:mime_type]
    end
    merged
  end

  def provider_file_from(provider_record, attachment_payload)
    provider_payload = fetch_provider_attachment_payload(provider_record)
    return build_provider_attachment_file(provider_payload, attachment_payload) if provider_attachment_available?(provider_payload)
    return mark_provider_media_unavailable if provider_attachment_unavailable?(provider_payload)

    nil
  end

  def fetch_provider_attachment_payload(provider_record)
    return if provider_record.blank?

    channel.provider_service.fetch_message_media(record: provider_record)
  rescue StandardError => e
    Rails.logger.info("[WHATSAPP WEB] Live provider media fetch failed for #{source_id}: #{e.message}")
    nil
  end

  def refetched_provider_message
    return @refetched_provider_message if defined?(@refetched_provider_message)

    @refetched_provider_message = perform_provider_message_refetch
  end

  def perform_provider_message_refetch
    return if source_id.blank?

    key = record[:key].to_h.deep_symbolize_keys
    channel.provider_service.fetch_message_by_source_id(
      source_id: source_id,
      remote_jid: WhatsappWeb::ProviderPayloadNormalizer.provider_lookup_remote_jid(key[:remoteJid]),
      from_me: ActiveModel::Type::Boolean.new.cast(key[:fromMe])
    ).to_h.deep_symbolize_keys.presence
  rescue StandardError => e
    Rails.logger.info("[WHATSAPP WEB] Live provider message lookup failed for #{source_id}: #{e.message}")
    nil
  end

  def provider_attachment_available?(provider_payload)
    payload = provider_payload.to_h.deep_symbolize_keys
    payload.present? && payload[:unavailable] != true && payload[:base64].present?
  end

  def provider_attachment_unavailable?(provider_payload)
    provider_payload.to_h.deep_symbolize_keys[:unavailable] == true
  end

  def build_provider_attachment_file(provider_payload, attachment_payload)
    payload = provider_payload.to_h.deep_symbolize_keys
    tempfile_from_base64(
      payload[:base64],
      filename: payload[:fileName].presence || attachment_payload[:fileName] || attachment_payload[:filename],
      content_type: payload[:mimetype].presence || attachment_payload[:mimetype] || attachment_payload[:mime_type],
      media_kind: media_kind_for(attachment_payload)
    )
  end

  def mark_provider_media_unavailable
    @provider_media_unavailable = true
    nil
  end

  def media_kind_for(attachment_payload)
    attachment_payload[:media_kind] || WhatsappWeb::MediaMimeNormalizer.extract_media_node(record)[:media_kind]
  end

  def tempfile_from_base64(base64, filename:, content_type:, media_kind: nil)
    normalized_type = WhatsappWeb::MediaMimeNormalizer.normalize_mime_type(content_type, filename: filename, media_kind: media_kind)
    sanitized_name = WhatsappWeb::MediaMimeNormalizer.sanitize_filename(filename, mime_type: normalized_type, media_kind: media_kind)
    tempfile = Tempfile.new(['whatsapp-web', File.extname(sanitized_name)])
    tempfile.binmode
    tempfile.write(Base64.decode64(base64))
    tempfile.rewind
    tempfile.define_singleton_method(:original_filename) { sanitized_name }
    tempfile.define_singleton_method(:content_type) { normalized_type }
    tempfile
  end
end
