class Whatsapp::CoexistenceHistoryFailureRecoveryJob < MutexApplicationJob
  class InvalidRecoveryStateError < StandardError; end
  class EnqueueError < StandardError; end

  BATCH_SIZE = 10
  RECOVERY_INTERVAL = 5.seconds
  RECOVERY_LOCK_TIMEOUT = 30.minutes

  queue_as :whatsappweb_history_recovery

  retry_on Whatsapp::WabaLivePriority::LiveTrafficPendingError, wait: 15.seconds, attempts: :unlimited, jitter: 0.5
  retry_on MutexApplicationJob::LockAcquisitionError, wait: 15.seconds, attempts: :unlimited, jitter: 0.5
  retry_on Whatsapp::WabaLock::LockAcquisitionError, wait: 15.seconds, attempts: :unlimited, jitter: 0.5
  discard_on ActiveRecord::RecordNotFound

  def perform(channel_id, raw_identity, after_failure_id = nil)
    channel = Channel::Whatsapp.find(channel_id)
    identity = raw_identity.to_h.with_indifferent_access
    validate_recovery!(channel, identity)

    result = nil
    with_recovery_lock(channel, identity) do
      result = perform_batch(channel, identity, after_failure_id)
    end
    result
  end

  private

  def with_recovery_lock(channel, identity, &)
    waba_id = identity[:business_account_id]
    defer_for_live_traffic!(waba_id)
    Whatsapp::WabaLock.new(waba_id).with_lock do
      defer_for_live_traffic!(waba_id)
      with_lock(recovery_lock_key(channel, identity), RECOVERY_LOCK_TIMEOUT, &)
    end
  end

  def perform_batch(channel, identity, after_failure_id)
    channel.reload
    validate_recovery!(channel, identity)
    touch_recovery_lease!(channel, identity)
    batch = next_batch(channel, after_failure_id)
    return complete_batch(channel, identity) if batch.empty?

    failure_ids = batch.pluck('id')
    replay = replay_failures(channel, failure_ids)
    advance_recovery!(channel, identity, failure_ids.last)
    { status: 'replayed', requested_count: replay[:requested_ids].size, failed_count: replay[:failed_ids].size }
  end

  def replay_failures(channel, failure_ids)
    Whatsapp::CoexistenceHistoryService
      .new(channel: channel, value: recovery_value(channel))
      .replay_failures(failure_ids: failure_ids)
  end

  def advance_recovery!(channel, identity, after_failure_id)
    return enqueue_next!(channel, identity, after_failure_id) if next_batch(channel, after_failure_id).any?
    return enqueue_next!(channel, identity, nil) if replayable_failures(channel).any?

    complete_recovery!(channel, identity)
  end

  def complete_batch(channel, identity)
    complete_recovery!(channel, identity)
    { status: 'complete', requested_count: 0, failed_count: 0 }
  end

  def next_batch(channel, after_failure_id)
    replayable_failures(channel)
      .select { |failure| after_failure_id.blank? || failure['id'] > after_failure_id.to_s }
      .first(BATCH_SIZE)
  end

  def replayable_failures(channel)
    failures = Array(channel.reload.provider_config.dig('coexistence_sync', 'history_failed_messages'))
               .map(&:stringify_keys)
               .select { |failure| failure['id'].present? && failure['message'].present? }
    ready_media_ids = existing_media_target_ids(channel, failures)

    failures.select { |failure| failure['kind'] != 'history_media' || ready_media_ids.include?(failure['id'].to_s) }
            .sort_by { |failure| failure['id'] }
  end

  def existing_media_target_ids(channel, failures)
    media_ids = failures.filter_map do |failure|
      failure['id'].to_s if failure['kind'] == 'history_media'
    end
    return Set.new if media_ids.empty?

    Message.where(inbox_id: channel.inbox.id, source_id: media_ids).pluck(:source_id).to_set(&:to_s)
  end

  def enqueue_next!(channel, identity, after_failure_id)
    next_job = self.class.set(wait: RECOVERY_INTERVAL).perform_later(channel.id, identity.to_h, after_failure_id)
    return if next_job.successfully_enqueued?

    raise EnqueueError, next_job.enqueue_error&.message || 'Could not enqueue the next local history recovery batch'
  end

  def complete_recovery!(channel, identity)
    channel.with_lock do
      config = channel.reload.provider_config.deep_dup
      sync = config['coexistence_sync'].to_h
      next unless identity_matches_sync?(sync, identity)

      sync = sync.except('failure_recovery_id', 'failure_recovery_started_at')
      sync['failure_recovery_completed_at'] = Time.current.iso8601
      sync = completed_sync(sync) if Array(sync['history_failed_messages']).empty?
      config['coexistence_sync'] = sync
      channel.persist_provider_config_state!(config)
    end
  end

  def touch_recovery_lease!(channel, identity)
    channel.with_lock do
      config = channel.provider_config.deep_dup
      sync = config['coexistence_sync'].to_h
      raise InvalidRecoveryStateError, 'History failure recovery identity changed' unless identity_matches_sync?(sync, identity)

      sync['failure_recovery_started_at'] = Time.current.iso8601(6)
      config['coexistence_sync'] = sync
      channel.persist_provider_config_state!(config)
    end
  end

  def completed_sync(sync)
    if sync['history_progress'].to_i >= 100 && sync['smb_app_state_sync_request_state'] == 'completed'
      sync.merge(
        'state' => 'completed',
        'history_request_state' => 'completed',
        'completed_at' => Time.current.iso8601
      ).except('last_error')
    else
      sync.merge(
        'state' => 'manual_recovery_required',
        'last_error' => 'Persisted history failures were replayed locally; full provider synchronization completion could not be verified'
      )
    end
  end

  def validate_target_channel!(channel)
    return if eligible_target_channel?(channel)

    raise InvalidRecoveryStateError, 'Channel is not eligible for local coexistence history recovery'
  end

  def eligible_target_channel?(channel)
    config = channel.provider_config.to_h
    cloud_coexistence?(channel, config) && active_inbox?(channel) && provider_identity_present?(config)
  end

  def cloud_coexistence?(channel, config)
    channel.provider == 'whatsapp_cloud' && config['embedded_signup_flow'] == 'coexistence'
  end

  def active_inbox?(channel)
    channel.account&.active? && channel.inbox.present? && channel.inbox.deleting_at.blank?
  end

  def provider_identity_present?(config)
    config['business_account_id'].present? && config['phone_number_id'].present?
  end

  def validate_identity!(channel, identity)
    return if recovery_identity_matches?(channel, identity)

    raise InvalidRecoveryStateError, 'Coexistence recovery identity changed'
  end

  def validate_recovery!(channel, identity)
    validate_target_channel!(channel)
    validate_identity!(channel, identity)
  end

  def recovery_identity_matches?(channel, identity)
    config = channel.provider_config.to_h
    channel_identity_matches?(channel, identity) && provider_identity_matches?(config, identity) &&
      identity_matches_sync?(config['coexistence_sync'].to_h, identity)
  end

  def channel_identity_matches?(channel, identity)
    identity[:account_id].to_i == channel.account_id && identity[:provider].to_s == channel.provider &&
      normalize_phone(identity[:phone_number]) == normalize_phone(channel.phone_number)
  end

  def provider_identity_matches?(config, identity)
    identity[:business_account_id].to_s == config['business_account_id'].to_s &&
      identity[:phone_number_id].to_s == config['phone_number_id'].to_s
  end

  def identity_matches_sync?(sync, identity)
    sync['generation'].to_s == identity[:sync_generation].to_s &&
      sync['failure_recovery_id'].to_s == identity[:failure_recovery_id].to_s
  end

  def recovery_value(channel)
    {
      metadata: {
        phone_number_id: channel.provider_config['phone_number_id'],
        display_phone_number: normalize_phone(channel.phone_number)
      }
    }
  end

  def recovery_lock_key(channel, identity)
    "whatsapp:coexistence:history-failure-recovery:#{channel.id}:#{identity[:business_account_id]}"
  end

  def defer_for_live_traffic!(waba_id)
    return unless Whatsapp::WabaLivePriority.waiting?(waba_id)

    raise Whatsapp::WabaLivePriority::LiveTrafficPendingError, 'Live WhatsApp traffic is waiting for the WABA lock'
  end

  def normalize_phone(value)
    value.to_s.gsub(/\D/, '')
  end
end
