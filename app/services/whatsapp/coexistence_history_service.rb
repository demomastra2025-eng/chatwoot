class Whatsapp::CoexistenceHistoryService
  class MediaHydrationError < StandardError; end

  FailureReplayService = Whatsapp::CoexistenceHistoryFailureReplayService

  STATUS_MAP = {
    'sent' => 'sent',
    'delivered' => 'delivered',
    'read' => 'read',
    'played' => 'read',
    'error' => 'failed',
    'failed' => 'failed'
  }.freeze
  NON_MESSAGE_EVENT_TYPES = %w[edit errors reaction revoke].freeze

  def initialize(channel:, value:)
    @channel = channel
    @value = value.with_indifferent_access
  end

  def perform
    media_service, failures = import_media

    Array(@value[:history]).each do |history|
      history = history.with_indifferent_access
      if history[:errors].present?
        Whatsapp::CoexistenceHistoryErrorService.new(channel: @channel).record(history)
        update_progress(history[:metadata].to_h.with_indifferent_access)
        next
      end

      Array(history[:threads]).each do |thread|
        import_thread(thread.with_indifferent_access, failures)
      end
      update_progress(history[:metadata].to_h.with_indifferent_access)
    end

    replay_history_failures(media_service, failures)
    finalize_media(media_service, failures)
  end

  private

  def import_media
    service = Whatsapp::CoexistenceHistoryMediaService.new(channel: @channel, value: @value)
    [service, service.perform]
  end

  def replay_history_failures(media_service, failures)
    replay_failures, attempted_ids = history_failure_replay_service.perform do |thread_id, message, metadata|
      import_message(thread_id, message, metadata: metadata)
    end
    media_service.include_attempted_message_ids(attempted_ids)
    failures.concat(replay_failures)
  end

  def finalize_media(media_service, failures)
    failures.concat(media_service.replay_pending)
    media_service.finalize(failures)
    retryable_failures = failures.reject { |failure| failure.to_h.with_indifferent_access[:deferred] }
    return if retryable_failures.empty?

    raise MediaHydrationError, "Failed to import #{retryable_failures.size} WhatsApp Business app history messages"
  end

  def history_failure_replay_service
    @history_failure_replay_service ||= FailureReplayService.new(channel: @channel, history_entries: Array(@value[:history]))
  end

  def import_thread(thread, failures)
    captured = history_failure_replay_service.capture_thread_failures(thread, metadata: @value[:metadata]) do |thread_id, message, metadata|
      import_message(thread_id, message, metadata: metadata)
    end
    failures.concat(captured)
  end

  def import_message(thread_id, message, metadata: @value[:metadata])
    source_id = message[:id]
    raise ArgumentError, 'WhatsApp history message id is required' if source_id.blank?

    existing_message = Message.find_by(inbox_id: @channel.inbox.id, source_id: source_id)
    return if existing_message.present? && !Whatsapp::HistoryMessageNormalizer.media_follow_up?(existing_message, message)

    media_hydration_required = existing_message.present?

    outgoing = outgoing_message?(message)
    payload = build_message_payload(thread_id, message, outgoing, metadata)
    suppress_runtime_events do
      Whatsapp::IncomingMessageWhatsappCloudService.new(
        inbox: @channel.inbox,
        params: payload,
        outgoing_echo: outgoing
      ).perform
    end
    return if non_message_event?(message)

    imported_messages_for(message).each do |imported_message|
      raise "WhatsApp history media was not hydrated for #{source_id}" if media_hydration_required && imported_message.attachments.empty?

      apply_history_metadata(imported_message, message, outgoing)
    end
  end

  def build_message_payload(thread_id, message, outgoing, metadata)
    importable = Whatsapp::HistoryMessageNormalizer.importable(message).with_indifferent_access
    value = {
      messaging_product: 'whatsapp',
      metadata: metadata
    }

    if outgoing
      importable[:to] ||= thread_id
      value[:message_echoes] = [importable]
      field = 'smb_message_echoes'
    else
      value[:contacts] = [{ wa_id: thread_id, profile: { name: thread_id } }]
      value[:messages] = [importable]
      field = 'messages'
    end

    {
      object: 'whatsapp_business_account',
      entry: [{ id: @channel.provider_config['business_account_id'], changes: [{ field: field, value: value }] }]
    }.with_indifferent_access
  end

  def apply_history_metadata(imported_message, message, outgoing)
    timestamp = Time.zone.at(message[:timestamp].to_i)
    history_status = message.dig(:history_context, :status).presence || message[:status]
    attributes = imported_message.content_attributes.to_h.merge(
      'external_created_at' => timestamp.iso8601,
      'imported_history' => true,
      'whatsapp_history_import' => true,
      'whatsapp_history_status' => history_status,
      'whatsapp_history_original_type' => message[:type]
    )
    updates = { content_attributes: attributes, created_at: timestamp, updated_at: timestamp }
    status = STATUS_MAP[history_status.to_s.downcase]
    updates[:status] = Message.statuses.fetch(status) if outgoing && status.present?
    imported_message.update_columns(updates) # rubocop:disable Rails/SkipsModelValidations
  end

  def business_number?(number)
    business_phone_numbers.any? { |business_number| phone_number_matches?(number, business_number) }
  end

  def outgoing_message?(message)
    from_me = message.dig(:history_context, :from_me)
    return from_me if [true, false].include?(from_me)

    business_number?(message[:from])
  end

  def non_message_event?(message)
    NON_MESSAGE_EVENT_TYPES.include?(message[:type].to_s)
  end

  def imported_messages_for(message)
    source_ids = imported_message_source_ids(message)
    imported_messages = Message.where(inbox_id: @channel.inbox.id, source_id: source_ids).to_a
    return imported_messages if imported_messages.size == source_ids.size

    raise ActiveRecord::RecordNotFound, "Couldn't find all imported WhatsApp history messages"
  end

  def imported_message_source_ids(message)
    contacts_count = Array(message[:contacts]).size
    return [message[:id].to_s] unless message[:type].to_s == 'contacts' && contacts_count > 1

    Array.new(contacts_count) { |index| "#{message[:id]}:contact:#{index}" }
  end

  def business_phone_numbers = [@value.dig(:metadata, :display_phone_number), @channel.phone_number].compact_blank

  def phone_number_matches?(number, business_number)
    candidate = normalize_phone(number)
    configured = business_number.to_s.gsub(/[^\d*]/, '')
    return candidate == configured unless configured.include?('*')

    pattern = configured.split(/\*+/).map { |part| Regexp.escape(part) }.join('\\d+')
    candidate.match?(/\A#{pattern}\z/)
  end

  def normalize_phone(number) = number.to_s.gsub(/\D/, '')

  def suppress_runtime_events
    previous_value = Current.suppress_runtime_events
    Current.suppress_runtime_events = true
    yield
  ensure
    Current.suppress_runtime_events = previous_value
  end

  def update_progress(metadata)
    return if metadata.blank?

    @channel.with_lock do
      config = @channel.reload.provider_config.deep_dup
      sync = config['coexistence_sync'].to_h
      next if terminal_without_history_recovery?(sync)
      next if stale_progress?(metadata, sync)

      config['coexistence_sync'] = sync.merge(progress_attributes(metadata))
      @channel.persist_provider_config_state!(config)
    end
  end

  def terminal_without_history_recovery?(sync)
    Whatsapp::CoexistenceSyncService.terminal_state?(sync) &&
      !Whatsapp::CoexistenceSyncService.history_terminal_state?(sync)
  end

  def stale_progress?(metadata, sync)
    (history_position(metadata) <=> history_position(sync)) == -1
  end

  def history_position(value)
    value = value.with_indifferent_access
    [
      (value[:phase] || value[:history_phase]).to_i,
      (value[:progress] || value[:history_progress]).to_i,
      (value[:chunk_order] || value[:history_chunk_order]).to_i
    ]
  end

  def progress_attributes(metadata)
    progress = metadata[:progress].to_i
    phase = metadata[:phase].to_i
    {
      'history_progress' => progress,
      'history_phase' => phase,
      'history_chunk_order' => metadata[:chunk_order],
      'history_last_event_at' => Time.current.iso8601
    }
  end

  def update_sync_config(attributes)
    @channel.with_lock do
      config = @channel.reload.provider_config.deep_dup
      sync = config['coexistence_sync'].to_h.merge(attributes)
      config['coexistence_sync'] = sync
      @channel.persist_provider_config_state!(config)
    end
  end
end
