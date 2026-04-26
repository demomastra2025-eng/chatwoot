class WhatsappWeb::MediaAttachmentResolver
  Result = Struct.new(:file, :pending_backfill, keyword_init: true)

  def initialize(channel:, record:, source_id:)
    @channel = channel
    @record = record.to_h.deep_symbolize_keys
    @source_id = source_id.to_s
    @provider_media_unavailable = false
  end

  def resolve(attachment_payload)
    attachment_payload = attachment_payload.to_h.deep_symbolize_keys
    base64_file = file_from_base64(attachment_payload)
    return Result.new(file: base64_file, pending_backfill: false) if base64_file.present?

    remote_file = download_remote_attachment(attachment_payload)
    return Result.new(file: remote_file, pending_backfill: false) if remote_file.present?

    provider_file = download_provider_attachment(attachment_payload)
    return Result.new(file: provider_file, pending_backfill: false) if provider_file.present?

    Result.new(file: nil, pending_backfill: !@provider_media_unavailable)
  end

  private

  attr_reader :channel, :record, :source_id

  def file_from_base64(attachment_payload)
    return if attachment_payload[:base64].blank?

    tempfile_from_base64(
      attachment_payload[:base64],
      filename: attachment_payload[:fileName].presence || "whatsapp-web-#{SecureRandom.hex(8)}",
      content_type: attachment_payload[:mimetype].presence || 'application/octet-stream'
    )
  end

  def download_remote_attachment(attachment_payload)
    return if attachment_payload[:mediaUrl].blank?

    Down.download(attachment_payload[:mediaUrl])
  rescue Down::ClientError => e
    Rails.logger.warn("[WHATSAPP WEB] Skipping unavailable media attachment #{source_id}: #{e.message}")
    nil
  end

  def download_provider_attachment(attachment_payload)
    provider_file = provider_file_from(record, attachment_payload)
    return provider_file if provider_file.present? || @provider_media_unavailable

    provider_file_from(refetch_provider_message, attachment_payload)
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

  def refetch_provider_message
    key = record[:key].to_h.deep_symbolize_keys
    return if source_id.blank?

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
    provider_payload = provider_payload.to_h.deep_symbolize_keys
    provider_payload.present? && provider_payload[:unavailable] != true && provider_payload[:base64].present?
  end

  def provider_attachment_unavailable?(provider_payload)
    provider_payload.to_h.deep_symbolize_keys[:unavailable] == true
  end

  def build_provider_attachment_file(provider_payload, attachment_payload)
    provider_payload = provider_payload.to_h.deep_symbolize_keys
    tempfile_from_base64(
      provider_payload[:base64],
      filename: provider_payload[:fileName].presence || attachment_payload[:fileName],
      content_type: provider_payload[:mimetype].presence || attachment_payload[:mimetype]
    )
  end

  def mark_provider_media_unavailable
    @provider_media_unavailable = true
    nil
  end

  def tempfile_from_base64(base64, filename:, content_type:)
    filename = filename.presence || "whatsapp-web-#{SecureRandom.hex(8)}"
    content_type = content_type.presence || 'application/octet-stream'
    tempfile = Tempfile.new(['whatsapp-web', File.extname(filename)])
    tempfile.binmode
    tempfile.write(Base64.decode64(base64))
    tempfile.rewind
    tempfile.define_singleton_method(:original_filename) { filename }
    tempfile.define_singleton_method(:content_type) { content_type }
    tempfile
  end
end
