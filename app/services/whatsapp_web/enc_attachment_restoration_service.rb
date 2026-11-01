class WhatsappWeb::EncAttachmentRestorationService
  Result = Struct.new(:mode, :backup_dir, :total_candidates, :restored_count, :would_restore_count, :skipped_count, :failed_count, :items,
                      keyword_init: true) do
    def as_json(*) = to_h.transform_keys(&:to_s)
  end

  def initialize(apply: false, attachment_ids: nil, backup_dir: nil, evolution_database_url: ENV.fetch('EVOLUTION_DATABASE_URL', nil))
    @apply = ActiveModel::Type::Boolean.new.cast(apply)
    @attachment_ids = Array(attachment_ids).flat_map { |val| val.to_s.split(',') }.map(&:strip).reject(&:blank?).map(&:to_i).uniq
    @backup_dir = (backup_dir.presence || default_backup_dir).to_s
    @db_lookup = WhatsappWeb::EvolutionDatabaseMessageLookup.new(database_url: evolution_database_url)
  end

  def perform
    items = []
    candidate_attachments.find_each { |attachment| items << process_attachment(attachment) }
    build_summary(items)
  end

  private

  def default_backup_dir
    Rails.root.join('storage', 'onelink_backups', "whatsapp_web_enc_restore_#{Time.now.utc.strftime('%Y%m%dT%H%M%SZ')}")
  end

  def candidate_attachments
    scope = Attachment.joins(message: :inbox).left_joins(file_attachment: :blob).where(inboxes: { channel_type: 'Channel::WhatsappWeb' })
    return scope.where(id: @attachment_ids) if @attachment_ids.present?

    scope.where("LOWER(COALESCE(attachments.extension, '')) = 'enc' OR LOWER(COALESCE(active_storage_blobs.filename, '')) LIKE '%.enc'").distinct
  end

  def process_attachment(attachment)
    return skipped_item(attachment) unless encrypted_attachment?(attachment)

    old_filename = attachment.file.attached? ? attachment.file.filename.to_s : nil
    old_extension = attachment.extension
    stored_bytes = read_stored_blob_bytes(attachment)
    provider_record, meta = lookup_message_encryption_context(attachment.message)
    decrypted, source, failure_reason = resolve_decrypted_media(stored_bytes, provider_record, meta, attachment.message)
    return failed_item(attachment, failure_reason || 'unable_to_decrypt') if decrypted.blank?

    apply_restoration!(attachment, stored_bytes, decrypted) if @apply
    restored_item(attachment, decrypted, source, old_filename: old_filename, old_extension: old_extension)
  rescue StandardError => e
    failed_item(attachment, "#{e.class}: #{e.message}")
  end

  def skipped_item(attachment)
    { attachment_id: attachment.id, message_id: attachment.message_id, status: 'skipped', reason: 'already_restored' }
  end

  def encrypted_attachment?(attachment)
    attachment.extension.to_s.strip.casecmp('enc').zero? ||
      (attachment.file.attached? && attachment.file.filename.to_s.downcase.end_with?('.enc'))
  end

  def read_stored_blob_bytes(attachment)
    return unless attachment.file.attached?

    attachment.file.blob.open { |tempfile| File.binread(tempfile.path) }
  rescue StandardError => e
    Rails.logger.warn("[WHATSAPP WEB] Could not read stored .enc blob for attachment=#{attachment.id}: #{e.message}")
    nil
  end

  def lookup_message_encryption_context(message)
    channel = message&.inbox&.channel
    source_id = message&.source_id.to_s
    return [nil, {}] if channel.blank? || source_id.blank?

    http_record = fetch_http_record(channel, message, source_id)
    http_meta = WhatsappWeb::MediaDecryptor.extract_encryption_metadata(record: http_record)
    return [http_record, http_meta] if http_meta[:media_key].present?

    sql_record = @db_lookup.lookup(source_id: source_id, instance_name: channel.instance_name)
    sql_meta = WhatsappWeb::MediaDecryptor.extract_encryption_metadata(record: sql_record)
    [sql_record.presence || http_record, http_meta.compact_blank.merge(sql_meta.compact_blank)]
  end

  def fetch_http_record(channel, message, source_id)
    remote_jid = WhatsappWeb::ProviderPayloadNormalizer.provider_lookup_remote_jid(message.conversation&.contact_inbox&.source_id)
    channel.provider_service.fetch_message_by_source_id(source_id: source_id, remote_jid: remote_jid, from_me: message.outgoing?)
  rescue StandardError => e
    Rails.logger.info("[WHATSAPP WEB] HTTP message lookup failed for source_id=#{source_id}: #{e.message}")
    nil
  end

  def resolve_decrypted_media(stored_bytes, provider_record, meta, message)
    errors = []
    from_blob = try_decrypt_bytes(stored_bytes, meta, errors, 'stored_blob')
    return [from_blob, 'stored_blob', nil] if from_blob.present?

    from_provider = try_provider_media(message&.inbox&.channel, provider_record, meta, errors)
    return [from_provider, 'provider_media_api', nil] if from_provider.present?

    from_cdn = try_live_cdn_decrypt(meta, errors)
    return [from_cdn, 'live_cdn_decrypt', nil] if from_cdn.present?

    [nil, nil, format_resolution_error(errors)]
  end

  def format_resolution_error(errors)
    errors.any? ? errors.join('; ') : 'missing_media_key_and_provider_media'
  end

  def try_decrypt_bytes(bytes, meta, errors, label)
    return if bytes.blank? || meta[:media_key].blank?

    WhatsappWeb::MediaDecryptor.decrypt_bytes(encrypted_bytes: bytes, media_key: meta[:media_key], metadata: meta)
  rescue WhatsappWeb::MediaDecryptor::DecryptionError => e
    errors << "#{label}: #{e.message}"
    nil
  end

  def try_provider_media(channel, provider_record, meta, errors)
    return if channel.blank? || provider_record.blank?

    payload = channel.provider_service.fetch_message_media(record: provider_record).to_h.deep_symbolize_keys
    return if payload[:unavailable] == true || payload[:base64].blank?

    build_provider_decrypted_result(payload, meta)
  rescue StandardError => e
    errors << "provider_media_api: #{e.message}"
    nil
  end

  def build_provider_decrypted_result(payload, meta)
    plaintext = Base64.decode64(payload[:base64]).force_encoding(Encoding::BINARY)
    raw_name = payload[:fileName].presence || meta[:filename]
    raw_mime = payload[:mimetype].presence || meta[:mime_type]
    content_type = WhatsappWeb::MediaMimeNormalizer.normalize_mime_type(raw_mime, filename: raw_name, media_kind: meta[:media_kind])
    filename = WhatsappWeb::MediaMimeNormalizer.sanitize_filename(raw_name, mime_type: content_type, media_kind: meta[:media_kind])
    extension = WhatsappWeb::MediaMimeNormalizer.extension_for(mime_type: content_type, filename: filename, media_kind: meta[:media_kind])

    WhatsappWeb::MediaDecryptor::Result.new(
      plaintext: plaintext, content_type: content_type, filename: filename, extension: extension,
      file_type: WhatsappWeb::MediaMimeNormalizer.file_type_for(media_kind: meta[:media_kind], mime_type: content_type),
      hkdf_info: 'provider_base64', byte_size: plaintext.bytesize, sha256_hex: OpenSSL::Digest::SHA256.hexdigest(plaintext)
    )
  end

  def try_live_cdn_decrypt(meta, errors)
    return if meta[:url].blank? || meta[:media_key].blank?

    downloaded = Down.download(meta[:url])
    try_decrypt_bytes(File.binread(downloaded.path), meta, errors, 'live_cdn_decrypt')
  rescue Down::Error => e
    errors << "live_cdn_decrypt: #{e.message}"
    nil
  ensure
    downloaded.close! if downloaded.respond_to?(:close!)
  end

  def apply_restoration!(attachment, stored_bytes, decrypted)
    backup_original_attachment!(attachment, stored_bytes)
    attachment.skip_storage_limit_validation!
    attachment.file.attach(io: StringIO.new(decrypted.plaintext), filename: decrypted.filename, content_type: decrypted.content_type)
    attachment.update!(extension: decrypted.extension, file_type: decrypted.file_type)
    analyze_restored_blob(attachment)
    attachment.message.send(:send_update_event)
  end

  def analyze_restored_blob(attachment)
    attachment.file.blob.analyze if attachment.file.attached?
  rescue StandardError => e
    Rails.logger.warn("[WHATSAPP WEB] Blob analysis warning for restored attachment=#{attachment.id}: #{e.message}")
  end

  def backup_original_attachment!(attachment, stored_bytes)
    FileUtils.mkdir_p(@backup_dir)
    metadata = build_backup_metadata(attachment, attachment.file.attached? ? attachment.file.blob : nil)
    File.write(File.join(@backup_dir, "attachment_#{attachment.id}.json"), JSON.pretty_generate(metadata))
    File.binwrite(File.join(@backup_dir, "attachment_#{attachment.id}.enc"), stored_bytes) if stored_bytes.present?
  end

  def build_backup_metadata(attachment, blob)
    {
      attachment_id: attachment.id, message_id: attachment.message_id, account_id: attachment.account_id,
      source_id: attachment.message&.source_id, extension: attachment.extension, file_type: attachment.file_type
    }.merge(blob_backup_metadata(blob))
  end

  def blob_backup_metadata(blob)
    {
      blob_id: blob&.id, blob_key: blob&.key, blob_filename: blob&.filename&.to_s, blob_content_type: blob&.content_type,
      blob_byte_size: blob&.byte_size, blob_checksum: blob&.checksum, backed_up_at: Time.now.utc.iso8601
    }
  end

  def restored_item(attachment, decrypted, source, old_filename:, old_extension:)
    {
      attachment_id: attachment.id, message_id: attachment.message_id, source_id: attachment.message&.source_id,
      status: @apply ? 'restored' : 'would_restore', resolution_source: source, old_filename: old_filename, old_extension: old_extension,
      new_filename: decrypted.filename, new_content_type: decrypted.content_type, new_extension: decrypted.extension,
      new_file_type: decrypted.file_type, decrypted_byte_size: decrypted.byte_size, sha256: decrypted.sha256_hex
    }
  end

  def failed_item(attachment, reason)
    { attachment_id: attachment.id, message_id: attachment.message_id, source_id: attachment.message&.source_id, status: 'failed', reason: reason }
  end

  def build_summary(items)
    counts = items.group_by { |item| item[:status] }.transform_values(&:size)
    Result.new(
      mode: @apply ? 'apply' : 'dry_run', backup_dir: @apply ? @backup_dir : nil, total_candidates: items.size,
      restored_count: counts.fetch('restored', 0), would_restore_count: counts.fetch('would_restore', 0),
      skipped_count: counts.fetch('skipped', 0), failed_count: counts.fetch('failed', 0), items: items
    )
  end
end
