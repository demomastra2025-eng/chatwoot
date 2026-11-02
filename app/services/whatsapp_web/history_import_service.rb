class WhatsappWeb::HistoryImportService
  ATTACHMENT_PLACEHOLDER = '[Attachment]'.freeze
  MEDIA_ATTACHMENT_TYPES = {
    imageMessage: :image,
    videoMessage: :video,
    ptvMessage: :video,
    audioMessage: :audio,
    documentMessage: :file,
    stickerMessage: :image
  }.freeze

  pattr_initialize [:channel!, :records!]

  def perform
    Current.with_runtime_events_suppressed do
      counts = { messages_imported: 0, contacts_touched: {} }

      normalized_records.each do |record|
        contact_inbox = import_record(record)
        next if contact_inbox.blank?

        counts[:messages_imported] += 1
        counts[:contacts_touched][contact_inbox.contact_id] = true
      end

      {
        messages_imported: counts[:messages_imported],
        contacts_touched: counts[:contacts_touched].keys.size
      }
    end
  end

  private

  def normalized_records
    Array.wrap(records)
         .map { |record| record.to_h.deep_symbolize_keys }
         .sort_by { |record| record[:messageTimestamp].to_i }
  end

  def import_record(record)
    key = record[:key].to_h.deep_symbolize_keys
    source_id = key[:id].to_s
    remote_jid = key[:remoteJid].to_s
    from_me = ActiveModel::Type::Boolean.new.cast(key[:fromMe])
    return if source_id.blank? || remote_jid.blank?
    return if ignored_remote_jid?(remote_jid)
    return if remote_jid.end_with?('@g.us') && !channel.sync_groups?
    return if duplicate_message?(source_id)

    content = extract_text(record)
    attachment_payload = extract_attachment_payload(record)
    attachment_file = prepare_attachment_file(attachment_payload, source_id: source_id, record: record)
    content = resolve_content(content, attachment_payload: attachment_payload, attachment_file: attachment_file)
    return if skip_empty_history_record?(record, content: content, attachment_payload: attachment_payload, attachment_file: attachment_file)

    is_group = remote_jid.end_with?('@g.us')
    group_title = (record[:groupSubject] || record.dig(:groupMetadata, :subject) || record[:subject] || record[:chatName]).presence if is_group

    contact_inbox = WhatsappWeb::ContactSyncService.new(
      channel: channel,
      contact_payload: {
        remoteJid: remote_jid,
        remoteJidAlt: key[:remoteJidAlt],
        remoteLid: key[:remoteLid],
        pushName: is_group ? nil : record[:pushName],
        name: group_title
      },
      trust_payload_display_name: is_group ? group_title.present? : !from_me
    ).perform
    return if contact_inbox.blank?

    conversation = find_or_create_conversation(contact_inbox, message_time_for(record))
    message = build_message(
      conversation,
      contact_inbox,
      record,
      content: content,
      attachment_payload: attachment_payload,
      attachment_file: attachment_file
    )
    attach_history_payload(message, attachment_payload, attachment_file)
    message.save!
    restore_history_reply_reference!(message, reply_to: extract_stanza_id(record))

    contact_inbox
  rescue ActiveRecord::RecordNotUnique
    nil
  end

  def build_message(conversation, contact_inbox, record, content:, attachment_payload:, attachment_file:)
    key = record[:key].to_h.deep_symbolize_keys
    from_me = ActiveModel::Type::Boolean.new.cast(key[:fromMe])

    conversation.messages.build(
      account_id: channel.account_id,
      inbox_id: channel.inbox.id,
      message_type: from_me ? :outgoing : :incoming,
      sender: from_me ? nil : contact_inbox.contact,
      status: mapped_message_status(record, outgoing: from_me),
      source_id: key[:id].to_s,
      content: content,
      content_attributes: build_content_attributes(
        record,
        outgoing: from_me,
        attachment_payload: attachment_payload,
        attachment_file: attachment_file
      ),
      created_at: message_time_for(record),
      updated_at: message_time_for(record)
    ).tap do |message|
      message.skip_runtime_events = true
    end
  end

  def build_content_attributes(record, outgoing:, attachment_payload:, attachment_file:)
    content_attributes = {
      external_created_at: message_time_for(record).iso8601,
      imported_history: true
    }
    content_attributes[:external_echo] = true if outgoing
    if !outgoing && group_record?(record)
      sender_attrs = group_sender_attributes(record)
      content_attributes[:group_sender] = sender_attrs if sender_attrs.present?
    end

    reply_to = extract_stanza_id(record)
    content_attributes[:in_reply_to_external_id] = reply_to if reply_to.present?
    if history_attachment_unavailable?(attachment_payload, attachment_file)
      content_attributes[:history_attachment] = {
        unavailable: true,
        kind: attachment_payload[:file_type].to_s,
        file_name: attachment_payload[:file_name],
        mimetype: attachment_payload[:mimetype],
        media_url: attachment_payload[:media_url]
      }.compact
      content_attributes[:history_attachment][:deferred] = true if WhatsappWeb::HistoryMediaPolicy.deferred?(message_time_for(record))
    end
    content_attributes
  end

  def group_record?(record)
    record.dig(:key, :remoteJid).to_s.end_with?('@g.us')
  end

  def group_sender_attributes(record)
    key = record[:key].to_h.deep_symbolize_keys
    participant_jid = (key[:participant] || key[:participantAlt] || record[:participant]).to_s.presence
    sender_name = record[:pushName].to_s.strip.presence
    raw_user = participant_jid.to_s.split('@').first.to_s.split(':').first.to_s
    digits = raw_user.gsub(/\D/, '')
    phone_number = "+#{digits}" if participant_jid.to_s.end_with?('@s.whatsapp.net') && digits.present?
    display_name = sender_name || phone_number || raw_user.presence
    return if display_name.blank? && participant_jid.blank?

    {
      id: participant_jid || display_name,
      name: display_name,
      phone_number: phone_number
    }.compact
  end

  def find_or_create_conversation(contact_inbox, message_time)
    WhatsappWeb::ConversationSyncService.new(
      channel: channel,
      contact_inbox: contact_inbox,
      activity_at: message_time
    ).perform
  end

  def attach_history_payload(message, attachment_payload, attachment_file)
    return attach_location(message, attachment_payload) if attachment_payload[:kind] == :location
    return if attachment_payload.blank? || attachment_file.blank?

    message.attachments.new(
      account_id: message.account_id,
      file_type: attachment_payload[:file_type],
      file: {
        io: attachment_file,
        filename: attachment_file.original_filename,
        content_type: attachment_file.content_type
      }
    ).skip_storage_limit_validation!
  end

  def attach_location(message, attachment_payload)
    message.attachments.new(
      account_id: message.account_id,
      file_type: :location,
      coordinates_lat: attachment_payload[:latitude],
      coordinates_long: attachment_payload[:longitude],
      fallback_title: attachment_payload[:title],
      external_url: attachment_payload[:url]
    ).skip_storage_limit_validation!
  end

  def restore_history_reply_reference!(message, reply_to:)
    return if reply_to.blank?
    return if message.content_attributes.to_h['in_reply_to_external_id'].present?

    content_attributes = message.content_attributes.to_h.deep_stringify_keys.merge('in_reply_to_external_id' => reply_to)
    message.update_columns(content_attributes: content_attributes, updated_at: message.updated_at)
    message.content_attributes = content_attributes
  end

  def extract_text(record)
    message = raw_message(record)

    message[:conversation].presence ||
      message.dig(:extendedTextMessage, :text).presence ||
      message.dig(:imageMessage, :caption).presence ||
      message.dig(:videoMessage, :caption).presence ||
      message.dig(:ptvMessage, :caption).presence ||
      message.dig(:documentMessage, :caption).presence ||
      template_message_text(message).presence ||
      message.dig(:buttonsMessage, :contentText).presence ||
      message.dig(:buttonsResponseMessage, :selectedDisplayText).presence ||
      message.dig(:buttonsResponseMessage, :selectedButtonId).presence
  end

  def extract_attachment_payload(record)
    message = raw_message(record)
    return extract_location_attachment_payload(message[:locationMessage]) if message[:locationMessage].present?

    extract_media_attachment_payload(message)
  end

  def extract_location_attachment_payload(raw_location)
    payload = raw_location.to_h.deep_symbolize_keys
    {
      kind: :location,
      latitude: payload[:degreesLatitude] || payload[:latitude],
      longitude: payload[:degreesLongitude] || payload[:longitude],
      title: [payload[:name], payload[:address]].compact.join(', ').presence,
      url: payload[:url]
    }
  end

  def extract_media_attachment_payload(message)
    MEDIA_ATTACHMENT_TYPES.each do |key, file_type|
      payload = message[key]
      return build_media_attachment_payload(key.to_s, file_type, payload, message) if payload.present?
    end
    {}
  end

  def build_media_attachment_payload(media_kind, file_type, payload, message)
    attachment = payload.to_h.deep_symbolize_keys
    raw_name = attachment[:fileName] || attachment[:name]
    normalized_mime = WhatsappWeb::MediaMimeNormalizer.normalize_mime_type(attachment[:mimetype], filename: raw_name, media_kind: media_kind)
    top_message = record_top_message(message)
    resolved_url = WhatsappWeb::MediaDecryptor.resolve_media_url(
      attachment[:mediaUrl] || attachment[:url] || top_message[:mediaUrl],
      attachment[:directPath]
    )

    {
      kind: :media, media_kind: media_kind, file_type: file_type, raw_file_name: raw_name, raw_mimetype: attachment[:mimetype],
      file_name: WhatsappWeb::MediaMimeNormalizer.sanitize_filename(raw_name, mime_type: normalized_mime, media_kind: media_kind),
      mimetype: normalized_mime, media_url: resolved_url, base64: top_message[:base64] || attachment[:base64]
    }
  end

  def record_top_message(message)
    message.is_a?(Hash) ? message : {}
  end

  def prepare_attachment_file(attachment_payload, source_id:, record:)
    return if attachment_payload.blank? || attachment_payload[:kind] == :location
    return if WhatsappWeb::HistoryMediaPolicy.deferred?(message_time_for(record))

    attachment_file = file_from_base64_payload(attachment_payload)
    return attachment_file if attachment_file.present?
    return prepare_provider_first_history_file(record, attachment_payload, source_id) if provider_first_history?(record, attachment_payload)

    download_remote_attachment(attachment_payload, source_id: source_id, record: record) ||
      download_provider_attachment(record, attachment_payload, source_id: source_id)[:file]
  rescue StandardError => e
    Rails.logger.warn("[WHATSAPP WEB] Failed to import history attachment #{source_id}: #{e.message}")
    nil
  end

  def provider_first_history?(record, attachment_payload)
    prefer_provider_media_for_history? || encrypted_history_attachment?(record, attachment_payload)
  end

  def prepare_provider_first_history_file(record, attachment_payload, source_id)
    provider_result = download_provider_attachment(record, attachment_payload, source_id: source_id)
    return provider_result[:file] if provider_result[:file].present?

    decrypted = decrypt_encrypted_history_attachment(record, source_id, provider_result)
    return decrypted if decrypted.present?
    return if provider_result[:unavailable]

    download_remote_attachment(attachment_payload, source_id: source_id, record: record, fallback: true)
  end

  def encrypted_history_attachment?(record, attachment_payload)
    raw_meta = WhatsappWeb::MediaDecryptor.extract_encryption_metadata(record: record)
    return true if WhatsappWeb::MediaDecryptor.encrypted_media_payload?(raw_meta)

    WhatsappWeb::MediaDecryptor.encrypted_media_payload?(
      url: attachment_payload[:media_url] || raw_meta[:url],
      media_key: raw_meta[:media_key],
      direct_path: raw_meta[:direct_path],
      filename: attachment_payload[:raw_file_name] || attachment_payload[:file_name]
    )
  end

  def decrypt_encrypted_history_attachment(record, source_id, provider_result = {})
    raw_meta = WhatsappWeb::MediaDecryptor.extract_encryption_metadata(record: record)
    meta = merged_history_encryption_metadata(record, raw_meta, provider_result)
    return if meta[:url].blank? || meta[:media_key].blank?

    WhatsappWeb::MediaDecryptor.decrypt_remote_media(url: meta[:url], media_key: meta[:media_key], metadata: meta)
  rescue WhatsappWeb::MediaDecryptor::DecryptionError, Down::Error => e
    Rails.logger.info("[WHATSAPP WEB] History native media decryption failed for #{source_id}: #{e.class}: #{e.message}")
    nil
  end

  def merged_history_encryption_metadata(record, raw_meta, provider_result)
    return raw_meta if raw_meta[:url].present? && raw_meta[:media_key].present?

    refreshed = provider_result[:refreshed_record]
    refreshed = refetch_provider_message(record) if refreshed.blank? && !provider_result[:refetch_attempted]
    return raw_meta if refreshed.blank?

    WhatsappWeb::MediaDecryptor.merge_encryption_metadata(
      raw_meta,
      WhatsappWeb::MediaDecryptor.extract_encryption_metadata(record: refreshed)
    )
  end

  def file_from_base64_payload(attachment_payload)
    return if attachment_payload[:base64].blank?

    tempfile = Tempfile.new(['whatsapp-web-history', File.extname(attachment_payload[:file_name].to_s)])
    tempfile.binmode
    tempfile.write(Base64.decode64(attachment_payload[:base64]))
    tempfile.rewind
    annotate_attachment_file(tempfile, attachment_payload)
  end

  def download_remote_attachment(attachment_payload, source_id:, record: nil, fallback: false)
    media_url = attachment_payload[:media_url]
    return if media_url.blank? || encrypted_history_attachment?(record, attachment_payload)

    file = reject_encrypted_history_download(Down.download(media_url), media_url, source_id)
    return if file.blank?

    annotate_attachment_file(file, attachment_payload)
  rescue StandardError => e
    log_message = if fallback
                    "[WHATSAPP WEB] Direct history attachment fallback failed for #{source_id}: #{e.message}"
                  else
                    "[WHATSAPP WEB] Direct history attachment download failed for #{source_id}: #{e.message}; trying provider fallback"
                  end
    Rails.logger.info(log_message)
    nil
  end

  def reject_encrypted_history_download(file, media_url, source_id)
    orig_name = file.respond_to?(:original_filename) ? file.original_filename.to_s : ''
    return file unless orig_name.match?(/\.enc\z/i) || media_url.to_s.match?(%r{\.enc(?:\z|[?&#/])}i)

    file.close! if file.respond_to?(:close!)
    Rails.logger.warn("[WHATSAPP WEB] Blocked raw .enc history download for #{source_id}")
    nil
  end

  def annotate_attachment_file(file, attachment_payload)
    media_kind = attachment_payload[:media_kind]
    raw_name = attachment_payload[:file_name].to_s
    detected = detect_attachment_content_type(file, raw_name)
    chosen_mime = WhatsappWeb::MediaMimeNormalizer.concrete_mime?(detected) ? detected : attachment_payload[:mimetype]
    content_type = WhatsappWeb::MediaMimeNormalizer.normalize_mime_type(chosen_mime, filename: raw_name, media_kind: media_kind)
    file_name = WhatsappWeb::MediaMimeNormalizer.sanitize_filename(raw_name, mime_type: content_type, media_kind: media_kind)

    file.define_singleton_method(:original_filename) { file_name }
    file.define_singleton_method(:content_type) { content_type }
    file
  end

  def detect_attachment_content_type(file, file_name)
    rewind_attachment_file(file)
    detected_content_type = Marcel::MimeType.for(file, name: file_name)
    rewind_attachment_file(file)
    detected_content_type.presence
  rescue StandardError => e
    Rails.logger.info("[WHATSAPP WEB] Failed to detect attachment MIME type for #{file_name}: #{e.message}")
    nil
  end

  def rewind_attachment_file(file)
    file.rewind if file.respond_to?(:rewind)
  end

  def download_provider_attachment(record, attachment_payload, source_id:)
    provider_payload = fetch_provider_attachment_payload(record, source_id: source_id)
    if provider_attachment_available?(provider_payload)
      return { file: build_provider_attachment_file(provider_payload, attachment_payload, record), unavailable: false }
    end

    initial_unavailable = provider_attachment_unavailable?(provider_payload)
    return { file: nil, unavailable: true } if initial_unavailable && complete_record_encryption_metadata?(record)

    refreshed_record = refetch_provider_message(record)
    return { file: nil, unavailable: initial_unavailable, refetch_attempted: true } if refreshed_record.blank?
    if initial_unavailable && !refreshed_remote_jid_changed?(record, refreshed_record)
      return { file: nil, unavailable: true, refreshed_record: refreshed_record, refetch_attempted: true }
    end

    retry_provider_attachment_with_refreshed(refreshed_record, record, attachment_payload, source_id)
  end

  def retry_provider_attachment_with_refreshed(refreshed_record, record, attachment_payload, source_id)
    provider_payload = fetch_provider_attachment_payload(refreshed_record, source_id: source_id, refreshed: true)
    if provider_attachment_available?(provider_payload)
      file = build_provider_attachment_file(provider_payload, attachment_payload, record, refreshed_record)
      return { file: file, unavailable: false, refreshed_record: refreshed_record, refetch_attempted: true }
    end

    { file: nil, unavailable: provider_attachment_unavailable?(provider_payload), refreshed_record: refreshed_record, refetch_attempted: true }
  end

  def complete_record_encryption_metadata?(record)
    meta = WhatsappWeb::MediaDecryptor.extract_encryption_metadata(record: record)
    meta[:url].present? && meta[:media_key].present?
  end

  def refreshed_remote_jid_changed?(initial_record, refreshed_record)
    initial_jid = initial_record.to_h.deep_symbolize_keys.dig(:key, :remoteJid).to_s
    refreshed_jid = refreshed_record.to_h.deep_symbolize_keys.dig(:key, :remoteJid).to_s
    refreshed_jid.present? && refreshed_jid != initial_jid
  end

  def fetch_provider_attachment_payload(record, source_id:, refreshed: false)
    channel.provider_service.fetch_message_media(record: record)
  rescue StandardError => e
    stage = refreshed ? 'refreshed provider media fetch' : 'provider media fetch'
    Rails.logger.info("[WHATSAPP WEB] #{stage} failed for #{source_id}: #{e.message}")
    nil
  end

  def provider_attachment_available?(provider_payload)
    provider_payload.present? &&
      provider_payload[:unavailable] != true &&
      provider_payload[:base64].present?
  end

  def provider_attachment_unavailable?(provider_payload)
    provider_payload.present? && provider_payload[:unavailable] == true
  end

  def build_provider_attachment_file(provider_payload, attachment_payload, record = nil, refreshed_record = nil)
    merged_meta = WhatsappWeb::MediaDecryptor.merge_encryption_metadata(
      WhatsappWeb::MediaDecryptor.extract_encryption_metadata(record: record),
      WhatsappWeb::MediaDecryptor.extract_encryption_metadata(record: refreshed_record)
    )
    raw_name = provider_payload[:fileName].presence || merged_meta[:filename].presence || attachment_payload[:file_name]
    raw_mime = provider_payload[:mimetype].presence || merged_meta[:mime_type].presence || attachment_payload[:mimetype]
    attachment_payload[:mimetype] = WhatsappWeb::MediaMimeNormalizer.normalize_mime_type(
      raw_mime, filename: raw_name, media_kind: attachment_payload[:media_kind]
    )
    attachment_payload[:file_name] = WhatsappWeb::MediaMimeNormalizer.sanitize_filename(
      raw_name, mime_type: attachment_payload[:mimetype], media_kind: attachment_payload[:media_kind]
    )
    attachment_payload[:base64] = provider_payload[:base64]

    file_from_base64_payload(attachment_payload)
  end

  def refetch_provider_message(record)
    key = record[:key].to_h.deep_symbolize_keys
    source_id = key[:id].to_s
    remote_jid = provider_lookup_remote_jid(key)
    from_me = ActiveModel::Type::Boolean.new.cast(key[:fromMe])

    provider_record = channel.provider_service.fetch_message_by_source_id(
      source_id: source_id,
      remote_jid: remote_jid,
      from_me: from_me
    )
    return if provider_record.blank?

    provider_record.deep_symbolize_keys
  rescue StandardError => e
    Rails.logger.info("[WHATSAPP WEB] Provider message lookup failed for #{source_id}: #{e.message}")
    nil
  end

  def provider_lookup_remote_jid(key)
    WhatsappWeb::ProviderPayloadNormalizer.provider_lookup_remote_jid(
      WhatsappWeb::ProviderPayloadNormalizer.canonical_remote_jid(key[:remoteJid], key[:remoteJidAlt], key[:remoteLid])
    )
  end

  def skip_empty_history_record?(record, content:, attachment_payload:, attachment_file:)
    return false if content.present?
    return false if attachment_payload[:kind] == :location
    return false if attachment_file.present?

    Rails.logger.info(
      "[WHATSAPP WEB] Skipping empty history record #{record.dig(:key, :id)} of type #{history_message_type(record)}"
    )
    true
  end

  def duplicate_message?(source_id)
    Message.exists?(source_id: source_id, inbox_id: channel.inbox.id)
  end

  def resolve_content(content, attachment_payload:, attachment_file:)
    return content if content.present?
    return ATTACHMENT_PLACEHOLDER if history_attachment_unavailable?(attachment_payload, attachment_file)

    content
  end

  def history_attachment_unavailable?(attachment_payload, attachment_file)
    attachment_payload.present? &&
      attachment_payload[:kind] == :media &&
      attachment_file.blank?
  end

  def extract_stanza_id(record)
    context_info = record[:contextInfo].to_h.deep_symbolize_keys
    return context_info[:stanzaId] if context_info[:stanzaId].present?

    message = raw_message(record)
    %i[extendedTextMessage imageMessage videoMessage ptvMessage audioMessage documentMessage stickerMessage buttonsResponseMessage].each do |key|
      stanza_id = message.dig(key, :contextInfo, :stanzaId)
      return stanza_id if stanza_id.present?
    end

    nil
  end

  def template_message_text(message)
    template_payload = message[:templateMessage].to_h.deep_symbolize_keys
    template = template_payload[:hydratedTemplate].presence || template_payload[:hydratedFourRowTemplate].presence
    return if template.blank?

    title = template[:hydratedTitleText].presence
    content = template[:hydratedContentText].presence

    [title.present? ? "*#{title}*" : nil, content]
      .compact
      .join("\n")
      .presence
  end

  def mapped_message_status(record, outgoing:)
    return :sent unless outgoing

    statuses = Array.wrap(record[:MessageUpdate]).filter_map { |entry| entry.to_h.deep_symbolize_keys[:status].presence }
    latest_status = statuses.last.to_s

    case latest_status
    when 'READ'
      :read
    when 'DELIVERY_ACK', 'SERVER_ACK'
      :delivered
    when 'ERROR'
      :failed
    else
      :sent
    end
  end

  def raw_message(record)
    WhatsappWeb::MediaMimeNormalizer.unwrap_message_container(record[:message])
  end

  def history_message_type(record)
    raw_message(record).keys.first || record[:message].to_h.deep_symbolize_keys.keys.first || 'unknown'
  end

  def message_time_for(record)
    Time.zone.at(record[:messageTimestamp].to_i)
  end

  def ignored_remote_jid?(remote_jid)
    channel.ignored_remote_jid?(remote_jid)
  end

  def prefer_provider_media_for_history?
    channel.provider_service.prefer_provider_media_for_history?
  rescue StandardError
    false
  end
end
