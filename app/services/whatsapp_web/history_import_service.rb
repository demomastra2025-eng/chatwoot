class WhatsappWeb::HistoryImportService
  ATTACHMENT_PLACEHOLDER = '[Attachment]'.freeze

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
    return if source_id.blank? || remote_jid.blank?
    return if ignored_remote_jid?(remote_jid)
    return if remote_jid.end_with?('@g.us')
    return if outside_import_window?(record)
    return if duplicate_message?(source_id)

    content = extract_text(record)
    attachment_payload = extract_attachment_payload(record)
    attachment_file = prepare_attachment_file(attachment_payload, source_id: source_id, record: record)
    content = resolve_content(content, attachment_payload: attachment_payload, attachment_file: attachment_file)
    return if skip_empty_history_record?(record, content: content, attachment_payload: attachment_payload, attachment_file: attachment_file)

    contact_inbox = WhatsappWeb::ContactSyncService.new(
      channel: channel,
      contact_payload: {
        remoteJid: remote_jid,
        remoteJidAlt: key[:remoteJidAlt],
        remoteLid: key[:remoteLid],
        pushName: record[:pushName]
      }
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
    end
    content_attributes
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
      message.dig(:documentMessage, :caption).presence ||
      message.dig(:documentWithCaptionMessage, :message, :documentMessage, :caption).presence ||
      template_message_text(message).presence ||
      message.dig(:buttonsMessage, :contentText).presence ||
      message.dig(:buttonsResponseMessage, :selectedDisplayText).presence ||
      message.dig(:buttonsResponseMessage, :selectedButtonId).presence
  end

  def extract_attachment_payload(record)
    message = raw_message(record)

    if message[:locationMessage].present?
      payload = message[:locationMessage].to_h.deep_symbolize_keys
      return {
        kind: :location,
        latitude: payload[:degreesLatitude] || payload[:latitude],
        longitude: payload[:degreesLongitude] || payload[:longitude],
        title: [payload[:name], payload[:address]].compact.join(', ').presence,
        url: payload[:url]
      }
    end

    {
      imageMessage: :image,
      videoMessage: :video,
      audioMessage: :audio,
      documentMessage: :file,
      stickerMessage: :image
    }.each do |key, file_type|
      payload = message[key]
      next if payload.blank?

      attachment = payload.to_h.deep_symbolize_keys
      return {
        kind: :media,
        file_type: file_type,
        file_name: attachment[:fileName] || attachment[:name] || "whatsapp-web-#{SecureRandom.hex(8)}",
        mimetype: attachment[:mimetype] || 'application/octet-stream',
        media_url: attachment[:mediaUrl] || attachment[:url] || message[:mediaUrl],
        base64: message[:base64]
      }
    end

    {}
  end

  def prepare_attachment_file(attachment_payload, source_id:, record:)
    return if attachment_payload.blank? || attachment_payload[:kind] == :location

    attachment_file = file_from_base64_payload(attachment_payload)
    return attachment_file if attachment_file.present?

    if prefer_provider_media_for_history?
      provider_result = download_provider_attachment(record, attachment_payload, source_id: source_id)
      return provider_result[:file] if provider_result[:file].present?
      return if provider_result[:unavailable]

      return download_remote_attachment(attachment_payload, source_id: source_id, fallback: true)
    end

    attachment_file = download_remote_attachment(attachment_payload, source_id: source_id)
    return attachment_file if attachment_file.present?

    download_provider_attachment(record, attachment_payload, source_id: source_id)[:file]
  rescue StandardError => e
    Rails.logger.warn("[WHATSAPP WEB] Failed to import history attachment #{source_id}: #{e.message}")
    nil
  end

  def file_from_base64_payload(attachment_payload)
    return if attachment_payload[:base64].blank?

    tempfile = Tempfile.new(['whatsapp-web-history', File.extname(attachment_payload[:file_name].to_s)])
    tempfile.binmode
    tempfile.write(Base64.decode64(attachment_payload[:base64]))
    tempfile.rewind
    annotate_attachment_file(tempfile, attachment_payload)
  end

  def download_remote_attachment(attachment_payload, source_id:, fallback: false)
    return if attachment_payload[:media_url].blank?

    file = Down.download(attachment_payload[:media_url])
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

  def annotate_attachment_file(file, attachment_payload)
    file_name = attachment_payload[:file_name].to_s
    content_type = detect_attachment_content_type(file, file_name) || attachment_payload[:mimetype].presence || 'application/octet-stream'

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
    return { file: build_provider_attachment_file(provider_payload, attachment_payload), unavailable: false } if provider_attachment_available?(provider_payload)
    return { file: nil, unavailable: true } if provider_attachment_unavailable?(provider_payload)

    refreshed_record = refetch_provider_message(record)
    return { file: nil, unavailable: false } if refreshed_record.blank?

    provider_payload = fetch_provider_attachment_payload(refreshed_record, source_id: source_id, refreshed: true)
    return { file: build_provider_attachment_file(provider_payload, attachment_payload), unavailable: false } if provider_attachment_available?(provider_payload)
    return { file: nil, unavailable: true } if provider_attachment_unavailable?(provider_payload)

    { file: nil, unavailable: false }
  end

  def fetch_provider_attachment_payload(record, source_id:, refreshed: false)
    channel.provider_service.fetch_message_media(record: record)
  rescue StandardError => e
    stage = refreshed ? 'refreshed provider media fetch' : 'provider media fetch'
    Rails.logger.info("[WHATSAPP WEB] #{stage} failed for #{source_id}: #{e.message}")
    { unavailable: true }
  end

  def provider_attachment_available?(provider_payload)
    provider_payload.present? &&
      provider_payload[:unavailable] != true &&
      provider_payload[:base64].present?
  end

  def provider_attachment_unavailable?(provider_payload)
    provider_payload.present? && provider_payload[:unavailable] == true
  end

  def build_provider_attachment_file(provider_payload, attachment_payload)
    attachment_payload[:file_name] = provider_payload[:fileName].presence || attachment_payload[:file_name]
    attachment_payload[:mimetype] = provider_payload[:mimetype].presence || attachment_payload[:mimetype]
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
    %i[extendedTextMessage imageMessage videoMessage audioMessage documentMessage stickerMessage buttonsResponseMessage].each do |key|
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
    message = record[:message].to_h.deep_symbolize_keys
    associated_child_message = message.dig(:associatedChildMessage, :message)
    return associated_child_message.to_h.deep_symbolize_keys if associated_child_message.present?

    message
  end

  def history_message_type(record)
    raw_message(record).keys.first || record[:message].to_h.deep_symbolize_keys.keys.first || 'unknown'
  end

  def message_time_for(record)
    Time.zone.at(record[:messageTimestamp].to_i)
  end

  def outside_import_window?(record)
    window = channel.history_lookback_window
    return false if window.blank?

    message_time_for(record) < window.ago
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
