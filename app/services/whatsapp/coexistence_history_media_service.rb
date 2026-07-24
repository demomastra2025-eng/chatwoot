class Whatsapp::CoexistenceHistoryMediaService
  pattr_initialize [:channel!, :value!]

  def perform
    Array(value[:messages]).filter_map do |raw_message|
      hydrate(raw_message.with_indifferent_access)
      nil
    rescue StandardError => e
      failure_payload(raw_message, e)
    end
  end

  def replay_pending
    replayable_failures.filter_map do |failure|
      message = failure[:message].to_h.with_indifferent_access
      hydrate(message, metadata: failure[:metadata])
      nil
    rescue StandardError => e
      failure_payload(message, e, metadata: failure[:metadata])
    end
  end

  def include_attempted_message_ids(message_ids)
    @additional_attempted_message_ids = Array(@additional_attempted_message_ids) | Array(message_ids).map(&:to_s)
  end

  def finalize(failures)
    return if attempted_message_ids.empty? && failures.empty?

    channel.with_lock { reconcile_failures(failures) }
  end

  private

  def reconcile_failures(failures)
    config = channel.reload.provider_config.deep_dup
    sync = config['coexistence_sync'].to_h
    return if terminal_without_history_recovery?(sync)
    return if failures.empty? && Array(sync['history_failed_messages']).empty?

    reconciled = reconciled_failures(sync, failures)
    sync = reconciled.present? ? failed_state(sync, reconciled) : resolved_failure_state(sync)
    channel.persist_provider_config_state!(config.merge('coexistence_sync' => sync))
  end

  def reconciled_failures(sync, failures)
    failed_ids = failure_ids(failures)
    resolved_ids = attempted_message_ids - failed_ids
    existing = Array(sync['history_failed_messages']).reject do |failure|
      resolved_ids.include?(failure_id(failure))
    end
    (existing + failures).select { |failure| failure_id(failure).present? }
                         .index_by { |failure| failure_id(failure) }.values
  end

  def failed_state(sync, failures)
    sync.merge(
      'state' => 'history_failed',
      'history_failed_at' => Time.current.iso8601,
      'history_failed_messages' => failures
    )
  end

  def resolved_failure_state(sync)
    sync = sync.except('history_failed_at', 'history_failed_messages')
    error_state = persisted_history_error_state(sync)
    return sync.merge('state' => error_state) if error_state.present?

    sync.merge('state' => Whatsapp::CoexistenceSyncService.aggregate_state(sync.except('state'), fallback: 'syncing'))
  end

  def terminal_without_history_recovery?(sync)
    Whatsapp::CoexistenceSyncService.terminal_state?(sync) &&
      !Whatsapp::CoexistenceSyncService.history_terminal_state?(sync)
  end

  def persisted_history_error_state(sync)
    errors = Array(sync['history_errors']).map(&:with_indifferent_access)
    return if errors.empty?

    declined = errors.any? do |error|
      error[:code].to_i == Whatsapp::CoexistenceHistoryErrorService::DECLINED_ERROR_CODE
    end
    declined ? 'history_declined' : 'history_failed'
  end

  def attempted_message_ids
    @attempted_message_ids ||= begin
      top_level_messages = Array(value[:messages]) + Array(value[:message_echoes])
      history_messages = Array(value[:history]).flat_map do |history|
        Array(history.to_h.with_indifferent_access[:threads]).flat_map do |thread|
          Array(thread.to_h.with_indifferent_access[:messages])
        end
      end
      failure_ids(top_level_messages + history_messages) | Array(@additional_attempted_message_ids)
    end
  end

  def replayable_failures
    history_ids = failure_ids(history_messages)
    return [] if history_ids.empty?

    Array(channel.reload.provider_config.dig('coexistence_sync', 'history_failed_messages'))
      .map(&:with_indifferent_access)
      .select do |failure|
        failure[:kind] != 'history_thread' && failure[:message].present? && history_ids.include?(failure_id(failure))
      end
  end

  def history_messages
    Array(value[:history]).flat_map do |history|
      Array(history.to_h.with_indifferent_access[:threads]).flat_map do |thread|
        Array(thread.to_h.with_indifferent_access[:messages])
      end
    end
  end

  def failure_ids(messages)
    messages.filter_map { |message| failure_id(message).presence }.uniq
  end

  def failure_id(failure)
    failure = failure.to_h.with_indifferent_access
    (failure[:failure_key].presence || failure[:id]).to_s
  end

  def hydrate(message, metadata: value[:metadata])
    source_id = message[:id].to_s
    raise ArgumentError, 'WhatsApp history message id is required' if source_id.blank?

    target = Message.find_by(inbox_id: channel.inbox.id, source_id: source_id)
    return if hydrated?(target)
    raise ActiveRecord::RecordNotFound, "WhatsApp history placeholder not found for #{source_id}" if target.blank?

    unless Whatsapp::HistoryMessageNormalizer.media_follow_up?(target, message)
      raise ActiveRecord::RecordNotFound, "WhatsApp history media target is not a placeholder for #{source_id}"
    end

    suppress_runtime_events do
      Whatsapp::IncomingMessageWhatsappCloudService.new(
        inbox: channel.inbox,
        params: message_payload(message, target.outgoing?, metadata),
        outgoing_echo: target.outgoing?
      ).perform
    end

    target.reload
    raise "WhatsApp history media was not hydrated for #{source_id}" unless hydrated?(target)
  end

  def hydrated?(target)
    target.present? && target.content_attributes.to_h['whatsapp_history_media_follow_up'] == true && target.attachments.exists?
  end

  def message_payload(message, outgoing, metadata)
    webhook_context = value.except(:messages, :message_echoes, :history).merge(metadata: metadata)
    webhook_value = webhook_context.merge(outgoing ? { message_echoes: [message] } : { messages: [message] })
    field = outgoing ? 'smb_message_echoes' : 'messages'

    {
      object: 'whatsapp_business_account',
      entry: [{ id: channel.provider_config['business_account_id'], changes: [{ field: field, value: webhook_value }] }]
    }.with_indifferent_access
  end

  def suppress_runtime_events
    previous_value = Current.suppress_runtime_events
    Current.suppress_runtime_events = true
    yield
  ensure
    Current.suppress_runtime_events = previous_value
  end

  def safe_error(error)
    Meta::CredentialDataSanitizer.sanitize(
      error.message.to_s.first(200),
      secrets: Meta::CredentialDataSanitizer.channel_secrets(channel)
    )
  end

  def failure_payload(raw_message, error, metadata: value[:metadata])
    safe_message = Whatsapp::CoexistenceHistoryFailureReplayService.safe_payload(channel, raw_message)
    message_id = safe_message['id'].presence&.to_s
    return if message_id.blank?

    {
      id: message_id,
      error: safe_error(error),
      kind: 'history_media',
      message: safe_message,
      metadata: Whatsapp::CoexistenceHistoryFailureReplayService.safe_payload(channel, metadata),
      replayable: true
    }.compact
  end
end
