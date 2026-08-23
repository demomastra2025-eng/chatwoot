# Recovery coordinates one durable state machine across provider and local replay paths.
# rubocop:disable Metrics/ClassLength
class Whatsapp::CoexistenceSyncRecoveryService
  class EnqueueError < StandardError; end

  RECOVERABLE_STATES = %w[failed history_failed manual_recovery_required].freeze
  ACTIVE_STATES = %w[pending requesting requested reconciling syncing].freeze
  RECOVERY_CLAIM_TIMEOUT = 30.minutes
  PROVIDER_SYNC_WINDOW = 24.hours

  pattr_initialize [:channel!]

  def self.perform(channel_id)
    new(channel: Channel::Whatsapp.find(channel_id)).perform
  end

  def perform
    preparation = prepare_recovery
    return preparation if preparation[:status] == 'already_in_progress'

    return enqueue_local_recovery(preparation) if preparation[:status] == 'local_prepared'

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
    if recovery_in_progress?(previous_sync) || local_recovery_in_progress?(previous_sync)
      return { status: 'already_in_progress', generation: previous_sync['generation'] }
    end

    validate_recoverable_state!(previous_sync)
    validate_dead_history_drained!
    return prepare_local_recovery(config, previous_sync) if local_replay_available?(previous_sync)

    validate_provider_sync_window!(previous_sync)
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

  def enqueue_local_recovery(preparation)
    job = Whatsapp::CoexistenceHistoryFailureRecoveryJob.perform_later(channel.id, preparation[:identity])
    unless job.successfully_enqueued?
      rollback_local_recovery(preparation[:recovery_id])
      raise EnqueueError, job.enqueue_error&.message || 'Could not enqueue local coexistence history recovery'
    end

    { status: 'local_replay_enqueued', generation: preparation[:generation], job_id: job.job_id }
  end

  def prepare_local_recovery(config, previous_sync)
    recovery_id = SecureRandom.uuid
    sync = previous_sync.merge(
      'failure_recovery_id' => recovery_id,
      'failure_recovery_started_at' => Time.current.iso8601
    )
    config['coexistence_sync'] = sync
    channel.persist_provider_config_state!(config)
    {
      status: 'local_prepared',
      generation: sync['generation'],
      recovery_id: recovery_id,
      identity: local_recovery_identity(sync)
    }
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
    return if sync['state'] == 'request_outcome_unknown' && local_replay_available?(sync)

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

  def local_recovery_in_progress?(sync)
    return false if sync['failure_recovery_id'].blank? || sync['failure_recovery_started_at'].blank?

    Time.zone.parse(sync['failure_recovery_started_at'].to_s) >= RECOVERY_CLAIM_TIMEOUT.ago
  rescue ArgumentError
    false
  end

  def local_replay_available?(sync)
    Array(sync['history_failed_messages']).any? do |failure|
      failure.to_h.values_at('id', 'message').all?(&:present?)
    end
  end

  def validate_provider_sync_window!(sync)
    raw_onboarded_at = sync['onboarded_at'].to_s
    raise ArgumentError, 'Valid coexistence onboarding timestamp is required for provider recovery' if raw_onboarded_at.blank?

    onboarded_at = parse_onboarded_at(raw_onboarded_at)
    return if onboarded_at >= PROVIDER_SYNC_WINDOW.ago

    raise ArgumentError, 'Meta coexistence synchronization window has expired; local recovery data is required'
  end

  def parse_onboarded_at(value)
    Time.zone.parse(value)
  rescue ArgumentError
    raise ArgumentError, 'Valid coexistence onboarding timestamp is required for provider recovery'
  end

  def local_recovery_identity(sync)
    {
      account_id: channel.account_id,
      provider: channel.provider,
      business_account_id: channel.provider_config['business_account_id'],
      phone_number_id: channel.provider_config['phone_number_id'],
      phone_number: channel.phone_number,
      sync_generation: sync['generation'],
      failure_recovery_id: sync['failure_recovery_id']
    }
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

  def rollback_local_recovery(recovery_id)
    waba_id = channel.provider_config['business_account_id'].to_s
    Whatsapp::WabaLock.new(waba_id).with_lock do
      channel.with_lock do
        config = channel.reload.provider_config.deep_dup
        sync = config['coexistence_sync'].to_h
        next unless sync['failure_recovery_id'].to_s == recovery_id.to_s

        config['coexistence_sync'] = sync.except('failure_recovery_id', 'failure_recovery_started_at')
        channel.persist_provider_config_state!(config)
      end
    end
  end
end
# rubocop:enable Metrics/ClassLength
