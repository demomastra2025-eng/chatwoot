class Whatsapp::CoexistenceSyncRecoveryService
  class EnqueueError < StandardError; end

  RECOVERABLE_STATES = %w[failed history_failed manual_recovery_required].freeze
  ACTIVE_STATES = %w[pending requesting requested reconciling syncing].freeze
  RECOVERY_CLAIM_TIMEOUT = 30.minutes

  pattr_initialize [:channel!]

  def self.perform(channel_id)
    new(channel: Channel::Whatsapp.find(channel_id)).perform
  end

  def perform
    preparation = prepare_recovery
    return preparation if preparation[:status] == 'already_in_progress'

    enqueue_recovery(preparation)
  end

  private

  def prepare_recovery
    validate_channel!
    locked_waba_id = channel.provider_config['business_account_id'].to_s

    Whatsapp::WabaLock.new(locked_waba_id).with_lock do
      prepare_recovery_locked(locked_waba_id)
    end
  end

  def prepare_recovery_locked(locked_waba_id)
    channel.reload
    validate_channel!
    validate_waba_identity!(locked_waba_id)

    config = channel.provider_config.deep_dup
    previous_sync = config['coexistence_sync'].to_h
    return { status: 'already_in_progress', generation: previous_sync['generation'] } if recovery_in_progress?(previous_sync)

    validate_recoverable_state!(previous_sync)
    validate_dead_history_drained!
    generation = SecureRandom.uuid
    config['coexistence_sync'] = recovery_sync(previous_sync, generation)
    channel.persist_provider_config_state!(config)
    { status: 'prepared', generation: generation, previous_sync: previous_sync }
  end

  def enqueue_recovery(preparation)
    job = Whatsapp::CoexistenceSyncJob.perform_later(channel.id, preparation[:generation])
    unless job.successfully_enqueued?
      rollback_sync(preparation[:previous_sync], preparation[:generation])
      raise EnqueueError, job.enqueue_error&.message || 'Could not enqueue coexistence synchronization recovery'
    end

    { status: 'enqueued', generation: preparation[:generation], job_id: job.job_id }
  end

  def validate_channel!
    validate_channel_record!
    validate_channel_activity!
    validate_provider_config!
  end

  def validate_channel_record!
    return if channel.is_a?(Channel::Whatsapp)

    raise ArgumentError, 'WhatsApp channel is required'
  end

  def validate_channel_activity!
    raise ArgumentError, 'Active WhatsApp account is required' unless channel.account&.active?
    return if channel.inbox.present? && channel.inbox.deleting_at.blank?

    raise ArgumentError, 'Active WhatsApp inbox is required'
  end

  def validate_provider_config!
    config = channel.provider_config
    raise ArgumentError, 'Coexistence channel is required' unless config['embedded_signup_flow'] == 'coexistence'
    raise ArgumentError, 'WABA ID is required' if config['business_account_id'].blank?
    raise ArgumentError, 'Phone number ID is required' if config['phone_number_id'].blank?
    raise ArgumentError, 'Access token is required' if config['api_key'].blank?
  end

  def validate_waba_identity!(locked_waba_id)
    return if locked_waba_id == channel.provider_config['business_account_id'].to_s

    raise ArgumentError, 'WhatsApp WABA identity changed during recovery'
  end

  def validate_recoverable_state!(sync)
    return if RECOVERABLE_STATES.include?(sync['state']) || stale_recovery_claim?(sync)

    raise ArgumentError, "Coexistence sync state #{sync['state'].presence || 'missing'} is not recoverable"
  end

  def validate_dead_history_drained!
    return unless Whatsapp::CoexistenceDeadHistoryRecoveryJob.pending_payload?(channel)

    raise ArgumentError, 'Dead history payloads must be recovered before opening a fresh synchronization generation'
  end

  def recovery_in_progress?(sync)
    return false unless ACTIVE_STATES.include?(sync['state'].to_s)
    return false if sync['recovery_started_at'].blank?

    Time.zone.parse(sync['recovery_started_at'].to_s) >= RECOVERY_CLAIM_TIMEOUT.ago
  rescue ArgumentError
    false
  end

  def stale_recovery_claim?(sync)
    return false unless ACTIVE_STATES.include?(sync['state'].to_s)
    return false if sync['recovery_started_at'].blank?

    Time.zone.parse(sync['recovery_started_at'].to_s) < RECOVERY_CLAIM_TIMEOUT.ago
  rescue ArgumentError
    false
  end

  def recovery_sync(previous_sync, generation)
    now = Time.current
    failures = Array(previous_sync['history_failed_messages'])
    {
      'generation' => generation,
      'state' => 'pending',
      'onboarded_at' => now.iso8601,
      'deadline_at' => (now + 24.hours).iso8601,
      'recovery_started_at' => now.iso8601,
      'recovery_source_generation' => previous_sync['generation'],
      'recovery_source_state' => previous_sync['state'],
      'recovery_history_failed_messages_count' => failures.size,
      'recovery_contacts_quarantined_events_count' => previous_sync['contacts_quarantined_events_count'].to_i,
      'history_failed_messages' => failures.presence
    }.compact
  end

  def rollback_sync(previous_sync, generation)
    waba_id = channel.provider_config['business_account_id'].to_s
    Whatsapp::WabaLock.new(waba_id).with_lock do
      channel.with_lock do
        config = channel.reload.provider_config.deep_dup
        next unless config.dig('coexistence_sync', 'generation').to_s == generation.to_s

        config['coexistence_sync'] = previous_sync
        channel.persist_provider_config_state!(config)
      end
    end
  end
end
