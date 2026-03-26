class WhatsappWeb::IncomingEventService
  OUTGOING_ECHO_DELAY = 2.seconds
  MESSAGE_UPDATE_BACKFILL_DELAY = 3.seconds
  PROVIDER_HISTORY_SETTLE_DELAY = 15.seconds

  pattr_initialize [:channel!, :payload!]

  def perform
    case event_name
    when 'qrcode.updated'
      process_qrcode_update
    when 'connection.update'
      process_connection_update
    when 'status.instance'
      process_status_instance
    when 'messages.set'
      process_history_batch
    when 'messages.upsert', 'send.message'
      process_message_upsert
    when 'messages.delete'
      process_message_delete
    when 'messages.edited', 'send.message.update'
      process_message_edit
    when 'messages.update'
      process_message_update
    when 'contacts.upsert', 'contacts.update'
      process_contact_update
    when 'labels.edit'
      process_label_edit
    when 'labels.association'
      process_label_association
    when 'messaging-history.set'
      process_history_sync_complete
    end

    touch_last_synced_at!
  end

  private

  def event_name
    @event_name ||= payload[:event].to_s
  end

  def event_data
    @event_data ||= payload[:data].is_a?(Hash) ? payload[:data].to_h.deep_symbolize_keys : {}
  end

  def event_records
    @event_records ||= Array.wrap(payload[:data]).map { |entry| entry.to_h.deep_symbolize_keys }
  end

  def message_update_records
    @message_update_records ||= event_records.filter_map do |entry|
      WhatsappWeb::ProviderPayloadNormalizer.normalize_message_update(entry)
    end
  end

  def process_qrcode_update
    qrcode = normalized_qrcode_payload

    if qrcode.blank?
      mark_runtime_failure!(
        connection_state: 'refused',
        error_message: runtime_error_message(event_data) || 'QR code generation failed'
      )
      return
    end

    channel.update!(
      qr_code: qrcode,
      lifecycle_state: 'qr_ready',
      connection_state: 'connecting',
      last_error: nil,
      last_synced_at: Time.current,
      sync_state: channel.sync_state_payload.merge(
        'qr_generated_at' => Time.current.iso8601
      )
    )
  end

  def process_connection_update
    state = event_data[:state] || event_data[:status]
    normalized_state = normalize_connection_state(state)
    attributes = {
      connection_state: normalized_state,
      lifecycle_state: lifecycle_state_for(state),
      last_error: connection_update_error_message(normalized_state),
      last_synced_at: Time.current
    }

    if state.to_s == 'open'
      attributes[:qr_code] = {}
      attributes[:sync_state] = channel.sync_state_payload.merge('qr_generated_at' => nil)
    elsif %w[refused close].include?(normalized_state)
      attributes[:qr_code] = {}
      attributes[:sync_state] = channel.sync_state_payload.merge('qr_generated_at' => nil)
    end

    channel.update!(attributes)
    request_history_sync_if_provider_ready! if state.to_s == 'open'
  end

  def process_status_instance
    channel.update!(
      connection_state: 'close',
      lifecycle_state: 'failed',
      qr_code: {},
      last_error: runtime_error_message(event_data) || 'Provider reported a terminal WhatsApp Web failure',
      last_synced_at: Time.current,
      sync_state: channel.sync_state_payload.merge('qr_generated_at' => nil)
    )
  end

  def process_message_upsert
    return if group_message?
    return if ignored_remote_jid?

    if outgoing_echo_event?
      # Delay phone-originated echoes slightly so locally-sent messages have time
      # to persist their provider source_id before the echo webhook arrives.
      Channels::WhatsappWeb::OutgoingEchoJob.set(wait: OUTGOING_ECHO_DELAY).perform_later(
        channel.id,
        event_data.deep_stringify_keys
      )
      return
    end

    WhatsappWeb::IncomingMessageService.new(
      inbox: channel.inbox,
      params: event_data,
      outgoing_echo: false
    ).perform
  end

  def process_history_batch
    mark_connected_from_history_events!
  end

  def process_message_delete
    message = Message.find_by(source_id: event_data.dig(:key, :id).to_s, inbox_id: channel.inbox.id)
    return if message.blank?

    ActiveRecord::Base.transaction do
      message.update!(
        content: I18n.t('conversations.messages.deleted'),
        content_type: :text,
        content_attributes: (message.content_attributes || {}).merge(deleted: true)
      )
      message.attachments.destroy_all
    end
  end

  def process_message_edit
    key = event_data[:key].to_h
    message = Message.find_by(source_id: key[:id].to_s, inbox_id: channel.inbox.id)
    return if message.blank?

    message.update!(
      content: extract_text_from_payload(event_data[:editedMessage] || event_data[:message]),
      content_attributes: (message.content_attributes || {}).merge(edited: true)
    )
  end

  def process_message_update
    message_update_records.each do |update|
      next unless update.dig(:key, :fromMe)

      mapped_status = WhatsappWeb::ProviderPayloadNormalizer.map_message_status(update.dig(:update, :status))
      next if mapped_status.blank?

      message = Message.find_by(source_id: update.dig(:key, :id).to_s, inbox_id: channel.inbox.id)
      if message.blank?
        channel.record_echo_status_miss!(source_id: update.dig(:key, :id).to_s)
        log_missing_message_update(update)
        Channels::WhatsappWeb::MessageUpdateBackfillJob.set(wait: MESSAGE_UPDATE_BACKFILL_DELAY).perform_later(
          channel.id,
          update.deep_stringify_keys
        )
        next
      end

      WhatsappWeb::ProviderPayloadNormalizer.apply_message_status!(message, update.dig(:update, :status))
    end
  end

  def process_contact_update
    return unless channel.import_contacts?

    event_records.each do |record|
      WhatsappWeb::ContactSyncService.new(channel: channel, contact_payload: record).perform
    end
  end

  def process_label_edit
    return unless channel.sync_labels?

    WhatsappWeb::LabelSyncService.new(channel: channel).sync_label_definition(event_data)
  end

  def process_label_association
    return unless channel.sync_labels?

    WhatsappWeb::LabelSyncService.new(channel: channel).sync_label_association(event_data)
  end

  def process_history_sync_complete
    mark_connected_from_history_events!
    return unless channel.history_sync_enabled?

    channel.record_provider_history_snapshot!(
      message_count: event_data[:messageCount].to_i,
      contact_count: event_data[:contactCount].to_i
    )
    request_history_sync_for_provider_snapshot!
  end

  def group_message?
    event_data.dig(:key, :remoteJid).to_s.end_with?('@g.us')
  end

  def outgoing_echo_event?
    ActiveModel::Type::Boolean.new.cast(event_data.dig(:key, :fromMe))
  end

  def ignored_remote_jid?
    channel.ignored_remote_jid?(event_data.dig(:key, :remoteJid))
  end

  def mark_connected_from_history_events!
    return if channel.connection_state == 'open' &&
              channel.lifecycle_state == 'connected' &&
              channel.qr_code.blank? &&
              channel.last_error.blank?

    channel.update!(
      connection_state: 'open',
      lifecycle_state: 'connected',
      qr_code: {},
      last_error: nil,
      last_synced_at: Time.current,
      sync_state: channel.sync_state_payload.merge('qr_generated_at' => nil)
    )
  end

  def request_history_sync_if_provider_ready!
    return unless channel.provider_history_synced_at.present?
    return if channel.full_history_baseline_current?

    mode = channel.preferred_history_sync_mode
    channel.request_history_sync!(
      mode,
      expected_provider_history_synced_at: channel.provider_history_synced_at
    )
  end

  def request_history_sync_for_provider_snapshot!
    mode = channel.preferred_history_sync_mode
    wait = mode == 'full' ? PROVIDER_HISTORY_SETTLE_DELAY : nil

    channel.request_history_sync!(
      mode,
      wait: wait,
      expected_provider_history_synced_at: channel.provider_history_synced_at
    )
  end

  def normalize_connection_state(state)
    value = state.to_s
    return 'open' if value == 'open'
    return 'connecting' if value == 'connecting'
    return 'refused' if value == 'refused'

    'close'
  end

  def lifecycle_state_for(state)
    case state.to_s
    when 'open'
      'connected'
    when 'connecting'
      channel.qr_code.present? ? 'qr_ready' : 'waiting_for_qr'
    when 'refused'
      'failed'
    else
      'disconnected'
    end
  end

  def normalized_qrcode_payload
    raw_qrcode = event_data[:qrcode]
    return {} unless raw_qrcode.respond_to?(:to_h)

    raw_qrcode.to_h.deep_stringify_keys
             .slice('instance', 'pairingCode', 'pairing_code', 'code', 'base64')
             .compact
             .presence || {}
  end

  def connection_update_error_message(normalized_state)
    return nil if %w[open connecting].include?(normalized_state)

    provider_message = runtime_error_message(event_data)
    fallback_message = normalized_state == 'refused' ? 'Connection refused' : 'Connection closed'

    merged_runtime_message(
      normalized_state == 'refused' ? channel.last_error : nil,
      provider_message.presence || channel.last_error.presence || fallback_message
    )
  end

  def runtime_error_message(payload)
    data = payload.to_h.with_indifferent_access

    merged_runtime_message(
      data[:message],
      data[:status],
      data[:error].is_a?(String) ? data[:error] : nil,
      labeled_runtime_value('status reason', data[:statusReason]),
      labeled_runtime_value('status code', data[:statusCode]),
      labeled_runtime_value('disconnection reason', data[:disconnectionReasonCode]),
      stringify_runtime_value(data[:disconnectionObject])
    )
  end

  def merged_runtime_message(*messages)
    messages.flatten.filter_map do |message|
      value = message.to_s.strip
      value.presence
    end.uniq.presence&.join(' | ')
  end

  def labeled_runtime_value(label, value)
    return if value.blank?

    "#{label}: #{value}"
  end

  def stringify_runtime_value(value)
    return if value.blank?

    value.is_a?(String) ? value : value.to_json
  rescue StandardError
    value.to_s
  end

  def mark_runtime_failure!(connection_state:, error_message:)
    channel.update!(
      connection_state: connection_state,
      lifecycle_state: 'failed',
      qr_code: {},
      last_error: error_message,
      last_synced_at: Time.current,
      sync_state: channel.sync_state_payload.merge('qr_generated_at' => nil)
    )
  end

  def extract_text_from_payload(payload)
    body = payload.to_h.deep_symbolize_keys
    body[:conversation] ||
      body.dig(:extendedTextMessage, :text) ||
      body.dig(:imageMessage, :caption) ||
      body.dig(:videoMessage, :caption) ||
      body.dig(:documentMessage, :caption)
  end

  def log_missing_message_update(update)
    Rails.logger.warn(
      "[WHATSAPP WEB] Missing local message for messages.update "\
      "channel=#{channel.id} source_id=#{update.dig(:key, :id)} "\
      "remote_jid=#{update.dig(:key, :remoteJid)} status=#{update.dig(:update, :status)}"
    )
  end

  def touch_last_synced_at!
    return if channel.saved_change_to_last_synced_at?

    channel.update_column(:last_synced_at, Time.current)
  end
end
