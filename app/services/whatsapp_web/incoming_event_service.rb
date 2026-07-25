class WhatsappWeb::IncomingEventService
  OUTGOING_ECHO_DELAY = 2.seconds
  MESSAGE_UPDATE_BACKFILL_DELAY = 3.seconds
  PROVIDER_HISTORY_SETTLE_DELAY = 15.seconds
  NON_RECOVERABLE_DISCONNECTION_CODES = [401, 402, 403, 406, 428].freeze
  DISCONNECTED_STATUS_VALUES = %w[closed close logout logged_out disconnected].freeze
  AUTHENTICATION_REQUIRED_STATUS_VALUES = %w[reauth_required authentication_required].freeze
  FAILURE_STATUS_VALUES = %w[error failed refused bad_session].freeze
  LIFECYCLE_TERMINAL_STATUS_VALUES = (
    ['open'] + DISCONNECTED_STATUS_VALUES + AUTHENTICATION_REQUIRED_STATUS_VALUES + FAILURE_STATUS_VALUES
  ).freeze
  REMOVED_INSTANCE_MESSAGE = 'Evolution instance was removed. Run repair or reconnect to create a new session.'.freeze
  RUNTIME_STATE_EVENTS = %w[qrcode.updated connection.update status.instance logout.instance remove.instance].freeze

  pattr_initialize [:channel!, :payload!]

  def perform
    return if channel.inbox&.deleting?

    if RUNTIME_STATE_EVENTS.include?(event_name)
      return unless process_runtime_state_event
    else
      process_event
    end

    touch_last_synced_at!
  end

  private

  def process_event
    case event_name
    when 'qrcode.updated'
      process_qrcode_update
    when 'connection.update'
      process_connection_update
    when 'status.instance'
      process_status_instance
    when 'logout.instance'
      process_logout_instance
    when 'remove.instance'
      process_remove_instance
    when 'call'
      process_call
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
  end

  def process_runtime_state_event
    processed = channel.with_lock do
      channel.reload
      next false if superseded_lifecycle_operation_event?
      next false if unadoptable_lifecycle_operation_event?
      next false if stale_runtime_state_event?

      process_event
      sync_state = lifecycle_event_sync_state.merge('last_runtime_event_at' => runtime_event_watermark.iso8601)
      sync_state = sync_state.merge('lifecycle_operation_completed_at' => runtime_event_watermark.iso8601) if lifecycle_operation_terminal_event?
      channel.update!(sync_state: sync_state)
      true
    end

    processed == true
  end

  def stale_runtime_state_event?
    if matching_lifecycle_operation_event? && event_lifecycle_sequence.present?
      return event_lifecycle_sequence <= channel.sync_state_payload['last_runtime_event_sequence'].to_i
    end

    last_event_at = parse_event_time(channel.sync_state_payload['last_runtime_event_at'])
    last_event_at.present? && runtime_event_at < last_event_at
  end

  def superseded_lifecycle_operation_event?
    return false unless channel.lifecycle_operation_fence_active?
    return event_lifecycle_operation_id != channel.lifecycle_operation_id if event_lifecycle_operation_id.present?

    channel.lifecycle_operation_pending?
  end

  def unadoptable_lifecycle_operation_event?
    return false if event_lifecycle_operation_id.blank? || matching_lifecycle_operation_event?
    return false if adoptable_lifecycle_operation_event?

    true
  end

  def adoptable_lifecycle_operation_event?
    return false if event_lifecycle_sequence.blank?
    return normalized_qrcode_payload.present? if event_name == 'qrcode.updated'

    normalized_runtime_status_value.in?(%w[connecting reconnecting open])
  end

  def matching_lifecycle_operation_event?
    event_lifecycle_operation_id.present? &&
      ActiveSupport::SecurityUtils.secure_compare(event_lifecycle_operation_id, channel.lifecycle_operation_id.to_s)
  end

  def event_lifecycle_operation_id
    @event_lifecycle_operation_id ||= (
      event_data[:lifecycleOperationId] ||
      event_data[:lifecycle_operation_id] ||
      payload[:lifecycleOperationId] ||
      payload[:lifecycle_operation_id]
    ).to_s.presence
  end

  def event_lifecycle_sequence
    value = event_data[:lifecycleEventSequence] || event_data[:lifecycle_event_sequence]
    value.to_i if value.present?
  end

  def lifecycle_event_sync_state
    state = channel.sync_state_payload
    return state if event_lifecycle_operation_id.blank?

    same_operation = event_lifecycle_operation_id == channel.lifecycle_operation_id
    state.merge(
      'lifecycle_operation_id' => event_lifecycle_operation_id,
      'lifecycle_operation_kind' => same_operation ? channel.lifecycle_operation_kind : 'reauthorize',
      'lifecycle_operation_started_at' => same_operation ? state['lifecycle_operation_started_at'] : runtime_event_at.iso8601,
      'lifecycle_operation_completed_at' => nil,
      'last_runtime_event_sequence' => event_lifecycle_sequence || (state['last_runtime_event_sequence'] if same_operation)
    )
  end

  def lifecycle_operation_terminal_event?
    return false if event_lifecycle_operation_id.blank?
    return true if event_name.in?(%w[logout.instance remove.instance])

    return true if normalized_runtime_status_value.in?(LIFECYCLE_TERMINAL_STATUS_VALUES)
    return true if NON_RECOVERABLE_DISCONNECTION_CODES.include?(event_data[:disconnectionReasonCode].to_i)

    event_name == 'qrcode.updated' && normalized_qrcode_payload.blank?
  end

  def normalized_runtime_status_value
    (event_data[:status] || event_data[:state] || event_data[:connection]).to_s.downcase
  end

  def runtime_event_at
    @runtime_event_at ||= parse_event_time(payload[:date_time] || payload[:dateTime]) || Time.current
  end

  def runtime_event_watermark
    [parse_event_time(channel.sync_state_payload['last_runtime_event_at']), runtime_event_at].compact.max
  end

  def parse_event_time(value)
    value.present? ? Time.zone.parse(value.to_s) : nil
  rescue ArgumentError
    nil
  end

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
    return if scanned_auth_artifact_connecting?

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
    state = event_data[:state] || event_data[:status] || event_data[:connection]
    normalized_state = normalize_connection_state(state)
    if scanned_auth_artifact_update?(normalized_state)
      mark_auth_artifact_scanned!
      return
    end

    clear_auth_artifacts = %w[open reconnecting].include?(normalized_state)
    attributes = {
      connection_state: normalized_state,
      lifecycle_state: lifecycle_state_for(state),
      last_error: connection_update_error_message(normalized_state),
      last_synced_at: Time.current
    }

    if clear_auth_artifacts
      attributes[:qr_code] = {}
      attributes[:sync_state] = channel.sync_state_payload.merge('qr_generated_at' => nil)
    end

    channel.update!(attributes)
    request_history_sync_if_provider_ready! if state.to_s == 'open'
  end

  def process_status_instance
    normalized_state = status_instance_connection_state

    if normalized_state == 'close' && channel.auth_artifact_valid?
      channel.update!(
        connection_state: normalized_state,
        lifecycle_state: 'qr_ready',
        last_error: nil,
        last_synced_at: Time.current
      )
      return
    end

    channel.update!(
      connection_state: normalized_state,
      lifecycle_state: normalized_state == 'refused' ? 'failed' : 'disconnected',
      qr_code: {},
      last_error: status_instance_error_message(normalized_state),
      last_synced_at: Time.current,
      sync_state: channel.sync_state_payload.merge('qr_generated_at' => nil)
    )
  end

  def process_logout_instance
    channel.update!(
      connection_state: 'close',
      lifecycle_state: 'disconnected',
      qr_code: {},
      last_error: nil,
      last_synced_at: Time.current,
      sync_state: channel.sync_state_payload.merge('qr_generated_at' => nil)
    )
  end

  def process_remove_instance
    channel.update!(
      connection_state: 'close',
      lifecycle_state: 'disconnected',
      qr_code: {},
      last_error: REMOVED_INSTANCE_MESSAGE,
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
      mapped_status = WhatsappWeb::ProviderPayloadNormalizer.map_message_status(update.dig(:update, :status))
      next if mapped_status.blank?

      if update.dig(:key, :fromMe)
        process_outgoing_message_update(update)
      else
        process_incoming_message_update(update, mapped_status)
      end
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

  def process_call
    WhatsappWeb::CallEventService.new(
      channel: channel,
      payload: event_data
    ).perform
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
    channel.with_lock do
      channel.reload
      next unless channel.connection_state == 'open'
      next if channel.lifecycle_state == 'connected' && channel.qr_code.blank? && channel.last_error.blank?

      channel.update!(
        lifecycle_state: 'connected',
        qr_code: {},
        last_error: nil,
        last_synced_at: Time.current,
        sync_state: channel.sync_state_payload.merge('qr_generated_at' => nil)
      )
    end
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
    return 'reconnecting' if value == 'reconnecting'
    return 'refused' if value == 'refused'
    return 'close' if value.in?(%w[close closed disconnected])

    'close'
  end

  def lifecycle_state_for(state)
    case state.to_s
    when 'open'
      'connected'
    when 'connecting'
      return 'qr_scanned' if channel.lifecycle_state == 'qr_scanned' && channel.auth_artifact_scanned_recent?

      channel.qr_code.present? ? 'qr_ready' : 'waiting_for_qr'
    when 'reconnecting'
      'reconnecting'
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

  def scanned_auth_artifact_update?(normalized_state)
    return false unless channel.auth_artifact_valid?
    return false unless event_data.key?(:hasQr) && event_data[:hasQr] == false

    normalized_state == 'connecting' || (connection_state_missing? && channel.connection_state == 'connecting')
  end

  def connection_state_missing?
    event_data[:state].blank? && event_data[:status].blank? && event_data[:connection].blank?
  end

  def scanned_auth_artifact_connecting?
    channel.lifecycle_state == 'qr_scanned' && channel.connection_state == 'connecting' && channel.auth_artifact_scanned_recent?
  end

  def mark_auth_artifact_scanned!
    channel.update!(
      connection_state: 'connecting',
      lifecycle_state: 'qr_scanned',
      qr_code: {},
      last_error: nil,
      last_synced_at: Time.current,
      sync_state: channel.cleared_auth_artifact_sync_state.merge('auth_artifact_scanned_at' => Time.current.iso8601)
    )
  end

  def connection_update_error_message(normalized_state)
    return nil if %w[open connecting].include?(normalized_state)

    provider_message = runtime_error_message(event_data)
    fallback_message = case normalized_state
                       when 'refused'
                         'Connection refused'
                       when 'reconnecting'
                         'Connection lost, reconnecting automatically'
                       else
                         'Connection closed'
                       end
    resolved_message = if normalized_state == 'reconnecting'
                         provider_message.presence || fallback_message
                       else
                         provider_message.presence || channel.last_error.presence || fallback_message
                       end

    merged_runtime_message(
      normalized_state == 'refused' ? channel.last_error : nil,
      resolved_message
    )
  end

  def status_instance_connection_state
    status_value = event_data[:status].to_s.downcase
    return 'close' if DISCONNECTED_STATUS_VALUES.include?(status_value)
    return 'close' if AUTHENTICATION_REQUIRED_STATUS_VALUES.include?(status_value)
    return 'close' if NON_RECOVERABLE_DISCONNECTION_CODES.include?(event_data[:disconnectionReasonCode].to_i)
    return 'refused' if FAILURE_STATUS_VALUES.include?(status_value)
    return 'refused' if event_data[:disconnectionReasonCode].present?

    'close'
  end

  def status_instance_error_message(normalized_state)
    runtime_message = runtime_error_message(event_data)
    return runtime_message.presence || 'Provider reported a terminal WhatsApp Web failure' if normalized_state == 'refused'

    runtime_message.presence
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

  def process_outgoing_message_update(update)
    message = Message.find_by(source_id: update.dig(:key, :id).to_s, inbox_id: channel.inbox.id)
    if message.blank?
      channel.record_echo_status_miss!(source_id: update.dig(:key, :id).to_s)
      cache_pending_message_status!(update)
      log_pending_message_update_backfill(update)
      Channels::WhatsappWeb::MessageUpdateBackfillJob.set(wait: MESSAGE_UPDATE_BACKFILL_DELAY).perform_later(
        channel.id,
        update.deep_stringify_keys
      )
      return
    end

    WhatsappWeb::ProviderPayloadNormalizer.apply_message_status!(message, update.dig(:update, :status))
  end

  def process_incoming_message_update(update, mapped_status)
    return unless mapped_status == :read

    message = Message.find_by(
      source_id: update.dig(:key, :id).to_s,
      inbox_id: channel.inbox.id,
      message_type: :incoming
    )
    return if message.blank?

    sync_conversation_last_seen!(message.conversation, message.created_at)
  end

  def sync_conversation_last_seen!(conversation, last_seen_at)
    updates = {}
    previous_changes = {}
    timestamp = Time.current

    if conversation.agent_last_seen_at.blank? || conversation.agent_last_seen_at < last_seen_at
      updates[:agent_last_seen_at] = last_seen_at
      previous_changes['agent_last_seen_at'] = [conversation.agent_last_seen_at, last_seen_at]
    end

    if conversation.assignee_last_seen_at.blank? || conversation.assignee_last_seen_at < last_seen_at
      updates[:assignee_last_seen_at] = last_seen_at
      previous_changes['assignee_last_seen_at'] = [conversation.assignee_last_seen_at, last_seen_at]
    end

    return if updates.blank?

    conversation.update_columns(updates.merge(updated_at: timestamp))
    updates.each { |attribute, value| conversation[attribute] = value }
    conversation.updated_at = timestamp
    conversation.dispatch_conversation_updated_event(previous_changes)
  end

  def log_pending_message_update_backfill(update)
    Rails.logger.info(
      '[WHATSAPP WEB] Scheduled messages.update backfill for transient missing local message ' \
      "channel=#{channel.id} source_id=#{update.dig(:key, :id)} " \
      "remote_jid=#{update.dig(:key, :remoteJid)} status=#{update.dig(:update, :status)} " \
      "wait_seconds=#{MESSAGE_UPDATE_BACKFILL_DELAY}"
    )
  end

  def cache_pending_message_status!(update)
    source_id = update.dig(:key, :id).to_s
    status = update.dig(:update, :status)
    return if source_id.blank? || status.blank?

    WhatsappWeb::PendingMessageStatusCache.new(
      inbox_id: channel.inbox.id,
      source_id: source_id
    ).write(status)
  end

  def touch_last_synced_at!
    return if channel.saved_change_to_last_synced_at?

    channel.update_column(:last_synced_at, Time.current)
  end
end
