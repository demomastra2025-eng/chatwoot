class Whatsapp::WebhookCallbackRecoveryService
  CONFIG_KEY = 'webhook_callback_recovery'.freeze
  ACTIVE_STATES = %w[updating outcome_unknown failed].freeze

  attr_reader :generation

  def initialize(channel, waba_id, secrets: [], generation: nil)
    @channel = channel
    @waba_id = waba_id
    @secrets = secrets
    @generation = generation
  end

  def updating!(callback_url:, verify_token:, subscribed_fields:)
    start_new_attempt = @generation.blank?
    @generation ||= SecureRandom.uuid
    write!(
      'updating',
      target: target_attributes(callback_url, verify_token, subscribed_fields),
      start_new_attempt: start_new_attempt
    )
  end

  def resolved!(callback_url:, verify_token:, subscribed_fields:)
    write!(
      'resolved',
      target: target_attributes(callback_url, verify_token, subscribed_fields)
    )
  end

  def outcome_unknown!(callback_url:, verify_token:, subscribed_fields:, error:)
    write!(
      'outcome_unknown',
      target: target_attributes(callback_url, verify_token, subscribed_fields),
      error: error
    )
  end

  def failed!(callback_url:, verify_token:, subscribed_fields:, error:)
    write!(
      'failed',
      target: target_attributes(callback_url, verify_token, subscribed_fields),
      error: error
    )
  end

  def manual_recovery_required!(error)
    write!('manual_recovery_required', error: error, only_if: ACTIVE_STATES)
  end

  private

  def write!(state, target: {}, error: nil, only_if: nil, start_new_attempt: false)
    persist_unsaved_provider_config!
    @channel.with_lock do
      config = @channel.reload.provider_config.deep_dup
      recovery = config[CONFIG_KEY].to_h
      next false unless start_new_attempt || recovery['generation'].to_s == @generation.to_s
      next false unless transition_allowed?(recovery, only_if)

      config[CONFIG_KEY] = build_recovery_state(recovery, state, target, error)
      @channel.persist_provider_config_state!(config)
      true
    end
  end

  def transition_allowed?(recovery, only_if)
    only_if.blank? || only_if.include?(recovery['state'])
  end

  def build_recovery_state(recovery, state, target, error)
    updated = recovery.merge(
      target,
      'state' => state,
      'waba_id' => @waba_id,
      'generation' => @generation,
      'updated_at' => Time.current.iso8601
    )
    updated.merge!(transition_attributes(recovery, state))
    updated['last_error'] = sanitized_error_message(error) if error.present?
    updated.delete('last_error') if state == 'resolved'
    updated
  end

  def transition_attributes(recovery, state)
    return { 'attempt_count' => recovery.fetch('attempt_count', 0).to_i + 1, 'last_attempt_at' => Time.current.iso8601 } if state == 'updating'
    return { 'resolved_at' => Time.current.iso8601 } if state == 'resolved'

    {}
  end

  def target_attributes(callback_url, verify_token, subscribed_fields)
    {
      'callback_url' => callback_url,
      'verify_token_fingerprint' => OpenSSL::Digest::SHA256.hexdigest(verify_token.to_s),
      'subscribed_fields' => subscribed_fields
    }
  end

  def persist_unsaved_provider_config!
    return unless @channel.will_save_change_to_provider_config?

    # rubocop:disable Rails/SkipsModelValidations
    @channel.update_columns(provider_config: @channel.provider_config, updated_at: Time.current)
    # rubocop:enable Rails/SkipsModelValidations
  end

  def sanitized_error_message(error)
    secrets = [*@secrets, *Meta::CredentialDataSanitizer.channel_secrets(@channel)].compact_blank
    Meta::CredentialDataSanitizer.sanitize(error.message.to_s.first(5000), secrets: secrets)
  end
end
