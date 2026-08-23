class Whatsapp::CoexistenceHistoryFailureReplayService
  pattr_initialize [:channel!, :history_entries!]

  def self.failure_payload(channel:, thread_id:, message:, error:, metadata:)
    safe_message = safe_payload(channel, message)
    message_id = safe_message['id'].presence&.to_s
    return if message_id.blank?

    {
      id: message_id,
      error: safe_error(channel, error),
      kind: 'history_thread',
      thread_id: safe_payload(channel, { thread_id: thread_id })['thread_id'],
      message: safe_message,
      metadata: safe_payload(channel, metadata),
      replayable: true,
      deferred: error.is_a?(Whatsapp::IncomingMessageMutationService::TargetNotFoundError)
    }.compact
  end

  def self.safe_payload(channel, payload)
    Meta::CredentialDataSanitizer.sanitize(
      payload.to_h.deep_stringify_keys,
      secrets: Meta::CredentialDataSanitizer.channel_secrets(channel)
    )
  end

  def self.safe_error(channel, error)
    Meta::CredentialDataSanitizer.sanitize(
      error.message.to_s.first(200),
      secrets: Meta::CredentialDataSanitizer.channel_secrets(channel)
    )
  end
  private_class_method :safe_error

  def perform(only_ids: nil)
    attempted_ids = []
    failures = pending_failures(only_ids: only_ids).filter_map do |failure|
      replay_failure(failure, attempted_ids) { |*args| yield(*args) }
    end
    [failures, attempted_ids]
  end

  def capture_thread_failures(thread, metadata:)
    Array(thread[:messages]).filter_map do |raw_message|
      message = raw_message.with_indifferent_access
      yield(thread[:id], message, metadata)
      nil
    rescue Whatsapp::WabaLivePriority::LiveTrafficPendingError
      raise
    rescue StandardError => e
      self.class.failure_payload(
        channel: channel,
        thread_id: thread[:id],
        message: message,
        error: e,
        metadata: metadata
      )
    end
  end

  private

  def replay_failure(failure, attempted_ids)
    message = failure[:message].to_h.with_indifferent_access
    message_id = message[:id].presence&.to_s
    return if message_id.blank? || current_message_ids.include?(message_id)

    attempted_ids << message_id
    yield(failure[:thread_id], message, failure[:metadata])
    nil
  rescue Whatsapp::WabaLivePriority::LiveTrafficPendingError
    raise
  rescue StandardError => e
    self.class.failure_payload(
      channel: channel,
      thread_id: failure[:thread_id],
      message: message,
      error: e,
      metadata: failure[:metadata]
    )
  end

  def pending_failures(only_ids: nil)
    failures = history_thread_failures
    existing_targets = existing_mutation_targets(failures)
    failures = failures.select { |failure| mutation_target_available?(failure, existing_targets) }
    return failures if only_ids.nil?

    selected_ids = Array(only_ids).to_set(&:to_s)
    failures.select { |failure| selected_ids.include?(failure[:id].to_s) }
  end

  def history_thread_failures
    Array(channel.reload.provider_config.dig('coexistence_sync', 'history_failed_messages'))
      .map(&:with_indifferent_access)
      .select { |failure| failure[:kind] == 'history_thread' && failure[:message].present? }
  end

  def mutation_target_available?(failure, existing_targets)
    target_id = mutation_target_id(failure)
    target_id.blank? || existing_targets.include?(target_id)
  end

  def existing_mutation_targets(failures)
    target_ids = failures.filter_map { |failure| mutation_target_id(failure) }.uniq
    return Set.new if target_ids.empty?

    Message.where(inbox_id: channel.inbox.id, source_id: target_ids).pluck(:source_id).to_set(&:to_s)
  end

  def mutation_target_id(failure)
    message = failure[:message].to_h.with_indifferent_access
    target_id = case message[:type].to_s
                when 'edit', 'revoke'
                  message.dig(message[:type].to_sym, :original_message_id)
                when 'reaction'
                  message.dig(:reaction, :message_id)
                end
    target_id.presence&.to_s
  end

  def current_message_ids
    @current_message_ids ||= history_entries.flat_map do |history|
      Array(history.to_h.with_indifferent_access[:threads]).flat_map do |thread|
        Array(thread.to_h.with_indifferent_access[:messages]).filter_map do |message|
          message.to_h.with_indifferent_access[:id].presence&.to_s
        end
      end
    end
  end
end
