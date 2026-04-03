class WhatsappWeb::HistorySyncService
  BATCH_SIZE = 100

  pattr_initialize [:channel!, :mode, { sync_context: {} }]

  def perform
    starting_provider_history_synced_at = channel.provider_history_synced_at
    fulfilled_provider_history_synced_at = requested_provider_history_snapshot || starting_provider_history_synced_at
    message_count = 0
    contact_count = 0

    contact_count += sync_contacts if full_sync?
    contact_count += sync_chats if full_sync?
    synced_messages, message_contacts = sync_messages
    message_count += synced_messages
    contact_count += message_contacts

    persist_sync_state(
      message_count: message_count,
      contact_count: contact_count,
      fulfilled_provider_history_synced_at: fulfilled_provider_history_synced_at
    )
    request_follow_up_sync_if_provider_advanced!(starting_provider_history_synced_at)

    {
      messages_imported: message_count,
      contacts_touched: contact_count
    }
  rescue StandardError => e
    persist_sync_error(e.message, fulfilled_provider_history_synced_at: fulfilled_provider_history_synced_at)
    raise
  end

  private

  def sync_contacts
    return 0 unless channel.import_contacts?

    touched_contact_ids = {}
    page = 1

    loop do
      records = Array.wrap(channel.provider_service.fetch_contacts(page: page, offset: BATCH_SIZE))
      break if records.blank?

      records.each do |record|
        contact_inbox = WhatsappWeb::ContactSyncService.new(channel: channel, contact_payload: record).perform
        touched_contact_ids[contact_inbox.contact_id] = true if contact_inbox.present?
      end

      break if records.size < BATCH_SIZE

      page += 1
    end

    touched_contact_ids.keys.size
  end

  def sync_messages
    return [0, 0] unless channel.import_messages?

    response = channel.provider_service.fetch_messages(page: 1, offset: BATCH_SIZE, from: window_start)
    total_pages = [response.dig('messages', 'pages').to_i, 1].max
    imported_messages = 0
    touched_contacts = 0

    total_pages.downto(1) do |page|
      page_response = page == 1 ? response : channel.provider_service.fetch_messages(page: page, offset: BATCH_SIZE, from: window_start)
      records = page_response.dig('messages', 'records')
      next if records.blank?

      result = WhatsappWeb::HistoryImportService.new(channel: channel, records: records).perform
      imported_messages += result[:messages_imported]
      touched_contacts += result[:contacts_touched]
    end

    [imported_messages, touched_contacts]
  end

  def sync_chats
    return 0 unless channel.import_messages?

    touched_contact_ids = {}
    page = 1

    loop do
      records = Array.wrap(channel.provider_service.fetch_chats(page: page, offset: BATCH_SIZE))
      break if records.blank?

      records.each do |record|
        contact_inbox = sync_chat_record(record)
        touched_contact_ids[contact_inbox.contact_id] = true if contact_inbox.present?
      end

      break if records.size < BATCH_SIZE

      page += 1
    end

    touched_contact_ids.keys.size
  end

  def full_sync?
    mode.to_s == 'full'
  end

  def sync_chat_record(record)
    payload = record.to_h.deep_symbolize_keys
    remote_jid = payload[:remoteJid].to_s
    return if remote_jid.blank? || remote_jid.end_with?('@g.us')
    return if channel.ignored_remote_jid?(remote_jid)

    activity_at = chat_activity_at(payload)
    return if activity_at.present? && outside_import_window?(activity_at)

    contact_inbox = WhatsappWeb::ContactSyncService.new(
      channel: channel,
      contact_payload: {
        remoteJid: remote_jid,
        pushName: payload[:pushName],
        profilePicUrl: payload[:profilePicUrl]
      }
    ).perform
    return if contact_inbox.blank?

    WhatsappWeb::ConversationSyncService.new(
      channel: channel,
      contact_inbox: contact_inbox,
      activity_at: activity_at
    ).perform

    contact_inbox
  end

  def chat_activity_at(payload)
    value = payload[:updatedAt].presence ||
            payload.dig(:lastMessage, :messageTimestamp).presence ||
            payload.dig(:lastMessage, :createdAt).presence
    return if value.blank?

    case value
    when Numeric
      Time.zone.at(value.to_i)
    else
      value.respond_to?(:in_time_zone) ? value.in_time_zone : Time.zone.parse(value.to_s)
    end
  rescue ArgumentError
    nil
  end

  def outside_import_window?(timestamp)
    window = channel.history_lookback_window
    return false if window.blank?

    timestamp < window.ago
  end

  def window_start
    if full_sync?
      window = channel.history_lookback_window
      return window.ago if window.present?

      return nil
    end

    channel.last_incremental_sync_at ||
      channel.last_local_history_sync_finished_at ||
      channel.history_synced_at ||
      1.day.ago
  end

  def persist_sync_state(message_count:, contact_count:, fulfilled_provider_history_synced_at:)
    return channel.record_history_sync!(
      message_count: message_count,
      contact_count: contact_count,
      error: nil,
      fulfilled_provider_history_synced_at: fulfilled_provider_history_synced_at,
      sync_context: sync_context_payload
    ) if full_sync?

    channel.record_incremental_sync!(
      message_count: message_count,
      error: nil,
      fulfilled_provider_history_synced_at: fulfilled_provider_history_synced_at,
      sync_context: sync_context_payload
    )
  end

  def persist_sync_error(error, fulfilled_provider_history_synced_at:)
    if full_sync?
      channel.record_history_sync!(
        message_count: 0,
        contact_count: 0,
        error: error,
        fulfilled_provider_history_synced_at: fulfilled_provider_history_synced_at,
        sync_context: sync_context_payload
      )
    else
      channel.record_incremental_sync!(
        message_count: 0,
        error: error,
        fulfilled_provider_history_synced_at: fulfilled_provider_history_synced_at,
        sync_context: sync_context_payload
      )
    end
  end

  def request_follow_up_sync_if_provider_advanced!(starting_provider_history_synced_at)
    channel.reload
    return if channel.provider_history_synced_at.blank?
    return if channel.full_history_baseline_current?
    return if channel.history_sync_request_pending?
    return if starting_provider_history_synced_at.present? &&
              channel.provider_history_synced_at <= starting_provider_history_synced_at

    channel.request_history_sync!(
      channel.preferred_history_sync_mode,
      expected_provider_history_synced_at: channel.provider_history_synced_at
    )
  end

  def sync_context_payload
    @sync_context_payload ||= sync_context.to_h.with_indifferent_access
  end

  def requested_provider_history_snapshot
    value = sync_context_payload[:expected_provider_history_synced_at]
    return if value.blank?

    value.respond_to?(:in_time_zone) ? value.in_time_zone : Time.zone.parse(value.to_s)
  rescue ArgumentError
    nil
  end
end
