class Whatsapp::CoexistenceSyncService
  SYNC_TYPES = %w[smb_app_state_sync history].freeze
  TERMINAL_SYNC_STATES = %w[completed history_failed history_declined manual_recovery_required].freeze
  HISTORY_TERMINAL_STATES = %w[history_failed history_declined].freeze
  class RequestOutcomeUnknownError < StandardError; end
  class RequestAlreadyClaimedError < RequestOutcomeUnknownError; end

  def initialize(channel, generation: nil)
    @channel = channel
    @generation = generation.presence || channel.provider_config.dig('coexistence_sync', 'generation')
    @api_client = Whatsapp::FacebookApiClient.new(channel.provider_config['api_key'])
  end

  def self.terminal_state?(sync)
    TERMINAL_SYNC_STATES.include?(sync.to_h['state'])
  end

  def self.history_terminal_state?(sync)
    HISTORY_TERMINAL_STATES.include?(sync.to_h['state'])
  end

  def self.aggregate_state(sync, fallback:)
    sync = sync.to_h
    return sync['state'] if terminal_state?(sync)
    return 'completed' if SYNC_TYPES.all? { |sync_type| sync["#{sync_type}_request_state"] == 'completed' }
    return 'reconciling' if SYNC_TYPES.any? { |sync_type| sync["#{sync_type}_request_state"] == 'completed' }

    fallback
  end

  def perform
    validate_channel!
    locked_waba_id = waba_id

    Whatsapp::WabaLock.new(locked_waba_id).with_lock do
      @channel.reload
      validate_channel!
      next :stale unless waba_id.to_s == locked_waba_id.to_s && generation_matches?(sync_config)

      perform_locked
    end
  rescue Whatsapp::WabaLock::LockAcquisitionError, RequestAlreadyClaimedError
    raise
  rescue RequestOutcomeUnknownError => e
    persist_unknown_outcome(e)
    raise
  rescue StandardError => e
    persist_failure(e)
    raise
  end

  private

  def perform_locked
    sync = sync_config
    return sync if sync['state'] == 'requested' || TERMINAL_SYNC_STATES.include?(sync['state'])

    validate_deadline!(sync)
    update_sync_config('state' => 'requesting', 'request_started_at' => Time.current.iso8601)

    SYNC_TYPES.each do |sync_type|
      request_sync_type(sync_type)
    end

    sync = sync_config
    update_sync_config(
      'state' => self.class.aggregate_state(sync, fallback: 'requested'),
      'requested_at' => Time.current.iso8601
    )
  end

  def validate_channel!
    raise ArgumentError, 'WhatsApp channel is required' unless @channel.is_a?(Channel::Whatsapp)

    validate_channel_eligibility!
    validate_provider_config!
  end

  def validate_channel_eligibility!
    raise ArgumentError, 'Active WhatsApp account is required' unless @channel.account&.active?
    raise ArgumentError, 'Active WhatsApp inbox is required' if @channel.inbox.blank? || @channel.inbox.deleting_at.present?
    raise ArgumentError, 'Coexistence channel is required' unless @channel.provider_config['embedded_signup_flow'] == 'coexistence'
  end

  def validate_provider_config!
    raise ArgumentError, 'Synchronization generation is required' if @generation.blank?
    raise ArgumentError, 'WABA ID is required' if waba_id.blank?
    raise ArgumentError, 'Phone number ID is required' if phone_number_id.blank?
    raise ArgumentError, 'Access token is required' if @channel.provider_config['api_key'].blank?
  end

  def validate_deadline!(sync)
    deadline = Time.zone.parse(sync['deadline_at'].to_s)
    raise 'WhatsApp Business app synchronization deadline has expired' if deadline.blank? || Time.current > deadline
  rescue ArgumentError
    raise 'WhatsApp Business app synchronization deadline is invalid'
  end

  def request_sync_type(sync_type)
    keys = sync_request_keys(sync_type)
    return unless prepare_sync_request(sync_type, keys)

    response = @api_client.request_smb_app_data(phone_number_id, sync_type)
    persist_accepted_request(sync_type, keys, response)
  rescue RequestOutcomeUnknownError
    raise
  rescue StandardError => e
    update_sync_config(keys[:state] => 'outcome_unknown', "#{sync_type}_last_error" => safe_error(e))
    raise RequestOutcomeUnknownError, "#{sync_type} request outcome is unknown; refusing an automatic retry"
  end

  def sync_request_keys(sync_type)
    {
      id: "#{sync_type}_request_id",
      state: "#{sync_type}_request_state",
      started_at: "#{sync_type}_request_started_at",
      requested_at: "#{sync_type}_requested_at"
    }
  end

  def prepare_sync_request(sync_type, keys)
    request_state_service.prepare(sync_type, keys)
  end

  def persist_accepted_request(sync_type, keys, response)
    request_state_service.persist_accepted(sync_type, keys, response)
  end

  def request_state_service
    @request_state_service ||= Whatsapp::CoexistenceSyncRequestStateService.new(@channel, generation: @generation)
  end

  def phone_number_id
    @channel.provider_config['phone_number_id']
  end

  def waba_id
    @channel.provider_config['business_account_id']
  end

  def sync_config
    @channel.reload.provider_config['coexistence_sync'].to_h.deep_dup
  end

  def update_sync_config(attributes)
    @channel.with_lock do
      config = @channel.reload.provider_config.deep_dup
      sync = config['coexistence_sync'].to_h
      next sync unless generation_matches?(sync)
      next sync if TERMINAL_SYNC_STATES.include?(sync['state'])

      persist_sync_config(config, sync.merge(monotonic_attributes(sync, attributes)))
    end
  end

  def monotonic_attributes(sync, attributes)
    attributes = attributes.stringify_keys
    SYNC_TYPES.each do |sync_type|
      key = "#{sync_type}_request_state"
      next unless TERMINAL_SYNC_STATES.include?(sync[key])
      next if attributes[key] == sync[key]

      attributes.delete(key)
    end
    attributes.delete('state') if sync['state'] == 'reconciling' && %w[requesting requested].include?(attributes['state'])
    attributes
  end

  def persist_sync_config(config, sync)
    config['coexistence_sync'] = sync
    @channel.persist_provider_config_state!(config)
  end

  def generation_matches?(sync)
    @generation.present? && sync.to_h['generation'].to_s == @generation.to_s
  end

  def safe_error(error)
    Meta::CredentialDataSanitizer.sanitize(error.message.to_s.first(500), secrets: [@channel.provider_config['api_key']])
  end

  def persist_failure(error)
    update_sync_config('state' => 'failed', 'last_error' => safe_error(error), 'failed_at' => Time.current.iso8601)
  rescue StandardError => e
    Rails.logger.error("[WHATSAPP] Failed to persist coexistence sync error: #{safe_error(e)}")
  end

  def persist_unknown_outcome(error)
    update_sync_config(
      'state' => 'request_outcome_unknown',
      'last_error' => safe_error(error),
      'failed_at' => Time.current.iso8601
    )
  rescue StandardError => e
    Rails.logger.error("[WHATSAPP] Failed to persist coexistence sync uncertainty: #{safe_error(e)}")
  end
end
