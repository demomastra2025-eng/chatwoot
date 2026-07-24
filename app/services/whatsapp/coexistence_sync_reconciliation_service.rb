class Whatsapp::CoexistenceSyncReconciliationService
  SYNC_TYPES = Whatsapp::CoexistenceSyncService::SYNC_TYPES
  REQUEST_CLAIM_TIMEOUT = 15.minutes
  UNRESOLVED_REQUEST_STATES = %w[requesting outcome_unknown].freeze

  def initialize(channel)
    @channel = channel
  end

  def reconcile_webhook!(field, generation: current_generation)
    sync_type = field.to_s
    return false unless SYNC_TYPES.include?(sync_type)

    status = update_from_webhook(sync_type, generation)
    return false if %i[stale ignored].include?(status)

    Whatsapp::CoexistenceSyncJob.perform_later(@channel.id, generation) if status == :continue
    true
  end

  def reconcile_unknown_outcome!(generation: current_generation)
    validate_channel!
    recovery_status = update_unknown_outcome(generation)
    @channel.prompt_reauthorization! if recovery_status == :manual_recovery_required
    recovery_status
  end

  def require_manual_recovery!(error, generation: current_generation)
    validate_channel!
    recovery_status = @channel.with_lock do
      config = @channel.reload.provider_config.deep_dup
      sync = config['coexistence_sync'].to_h
      next :stale unless coexistence_generation_matches?(config, sync, generation)
      next :resolved if Whatsapp::CoexistenceSyncService.terminal_state?(sync)

      SYNC_TYPES.each do |sync_type|
        key = request_state_key(sync_type)
        sync[key] = 'manual_recovery_required' if sync[key] == 'failed'
      end
      sync['state'] = 'manual_recovery_required'
      sync['last_error'] = sanitized_error(error)
      sync['recovery_required_at'] = Time.current.iso8601
      persist_sync_config(config, sync)
      :manual_recovery_required
    end
    @channel.prompt_reauthorization! if recovery_status == :manual_recovery_required
    recovery_status
  end

  private

  def current_generation
    @channel.provider_config.dig('coexistence_sync', 'generation')
  end

  def update_from_webhook(sync_type, generation)
    @channel.with_lock do
      config = @channel.reload.provider_config.deep_dup
      sync = config['coexistence_sync'].to_h
      next :stale unless coexistence_generation_matches?(config, sync, generation)
      next :ignored if Whatsapp::CoexistenceSyncService.terminal_state?(sync)
      next :ignored unless reconciliable_webhook?(sync, sync_type)

      mark_completed(sync, sync_type)
      persist_sync_config(config, sync)
      sync['state'] == 'reconciling' && unclaimed_sync_type?(sync) ? :continue : :updated
    end
  end

  def update_unknown_outcome(generation)
    @channel.with_lock do
      config = @channel.reload.provider_config.deep_dup
      sync = config['coexistence_sync'].to_h
      next :stale unless coexistence_generation_matches?(config, sync, generation)
      next :resolved if Whatsapp::CoexistenceSyncService.terminal_state?(sync)
      next :resolved unless unresolved_request?(sync)

      if reconciliation_deadline_expired?(sync)
        mark_manual_recovery_required(sync)
        persist_sync_config(config, sync)
        next :manual_recovery_required
      end

      persist_sync_config(config, sync) if mark_stale_claims_unknown(sync)
      :waiting
    end
  end

  def mark_completed(sync, sync_type)
    sync[request_state_key(sync_type)] = 'completed'
    sync["#{sync_type}_completed_at"] = Time.current.iso8601
    sync['state'] = sync_complete?(sync) ? 'completed' : 'reconciling'
    sync['completed_at'] = Time.current.iso8601 if sync['state'] == 'completed'
  end

  def mark_manual_recovery_required(sync)
    SYNC_TYPES.each do |sync_type|
      key = request_state_key(sync_type)
      sync[key] = 'manual_recovery_required' if UNRESOLVED_REQUEST_STATES.include?(sync[key])
    end
    sync['state'] = 'manual_recovery_required'
    sync['recovery_required_at'] = Time.current.iso8601
  end

  def persist_sync_config(config, sync)
    config['coexistence_sync'] = sync
    @channel.persist_provider_config_state!(config)
  end

  def coexistence_generation_matches?(config, sync, generation)
    generation.present? && config['embedded_signup_flow'] == 'coexistence' &&
      sync['generation'].to_s == generation.to_s
  end

  def reconciliable_webhook?(sync, sync_type)
    %w[requesting requested outcome_unknown].include?(sync[request_state_key(sync_type)])
  end

  def sync_complete?(sync)
    SYNC_TYPES.all? { |sync_type| sync[request_state_key(sync_type)] == 'completed' }
  end

  def unclaimed_sync_type?(sync)
    SYNC_TYPES.any? { |sync_type| sync[request_state_key(sync_type)].blank? }
  end

  def unresolved_request?(sync)
    SYNC_TYPES.any? { |sync_type| UNRESOLVED_REQUEST_STATES.include?(sync[request_state_key(sync_type)]) }
  end

  def mark_stale_claims_unknown(sync)
    changed = false
    SYNC_TYPES.each do |sync_type|
      next unless sync[request_state_key(sync_type)] == 'requesting'
      next unless stale_request_claim?(sync, sync_type)

      sync[request_state_key(sync_type)] = 'outcome_unknown'
      changed = true
    end
    sync['state'] = 'request_outcome_unknown' if changed
    changed
  end

  def stale_request_claim?(sync, sync_type)
    started_at = Time.zone.parse(sync[request_started_at_key(sync_type)].to_s)
    started_at.blank? || started_at <= REQUEST_CLAIM_TIMEOUT.ago
  rescue ArgumentError
    true
  end

  def request_state_key(sync_type)
    "#{sync_type}_request_state"
  end

  def request_started_at_key(sync_type)
    "#{sync_type}_request_started_at"
  end

  def reconciliation_deadline_expired?(sync)
    deadline = Time.zone.parse(sync['deadline_at'].to_s)
    deadline.blank? || Time.current >= deadline
  rescue ArgumentError
    true
  end

  def sanitized_error(error)
    Meta::CredentialDataSanitizer.sanitize(
      error.message.to_s.first(500),
      secrets: [@channel.provider_config.to_h['api_key']]
    )
  end

  def validate_channel!
    raise ArgumentError, 'WhatsApp channel is required' unless @channel.is_a?(Channel::Whatsapp)
  end
end
