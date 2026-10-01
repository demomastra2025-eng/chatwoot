require 'digest'

module Whatsapp::DurableReauthorization # rubocop:disable Metrics/ModuleLength
  DURABLE_REAUTHORIZATION_CONFIG_KEY = 'reauthorization_required'.freeze
  AUTHORIZATION_FAILURE_CONFIG_KEYS = %w[authorization_status authorization_error reauthorization_required].freeze
  TOKEN_HEALTH_CONFIG_KEY = 'token_health'.freeze

  def persist_provider_config_state!(config)
    # State-ledger writes must remain available while Meta is unavailable.
    # Callers serialize read/merge/write with the channel row lock.
    # rubocop:disable Rails/SkipsModelValidations
    update_columns(provider_config: config, updated_at: Time.current)
    # rubocop:enable Rails/SkipsModelValidations
  end

  def reauthorization_required?
    ActiveModel::Type::Boolean.new.cast(provider_config.to_h[self.class::DURABLE_REAUTHORIZATION_CONFIG_KEY]) || super
  end

  def prompt_reauthorization!
    with_durable_reauthorization_lock do
      persist_durable_reauthorization!(true)
      super
    end
  end

  def ensure_reauthorization_required_for_callback!
    previously_required = false
    with_durable_reauthorization_lock do
      previously_required = reauthorization_required?
      persist_durable_reauthorization!(true)
    end
    return false if previously_required

    invalidate_inbox_cache unless instance_of?(::AutomationRule)
    dispatch_reauthorization_inbox_update(false, true)
    true
  end

  def reauthorization_callback_snapshot
    with_durable_reauthorization_lock do
      reload
      config = provider_config.to_h
      {
        credential_fingerprint: Digest::SHA256.hexdigest(
          [config['business_account_id'], config['api_key']].map(&:to_s).join("\0")
        ),
        authorization_state: config.slice(*AUTHORIZATION_FAILURE_CONFIG_KEYS).deep_dup,
        authorization_error_count: authorization_error_count,
        base_reauthorization_required: ::Redis::Alfred.get(reauthorization_required_key).present?
      }
    end
  end

  def complete_reauthorization_after_callback!(snapshot)
    with_durable_reauthorization_lock do
      reload
      config = provider_config.to_h
      unless reauthorization_callback_snapshot_matches?(snapshot, config)
        persist_durable_reauthorization!(true)
        next false
      end

      begin
        reauthorized!
        clear_provider_authorization_error!
      rescue StandardError
        persist_durable_reauthorization!(true)
        raise
      end
      true
    end
  end

  def reauthorization_callback_snapshot_matches?(snapshot, config)
    snapshot.is_a?(Hash) &&
      provider_credential_fingerprint_matches?(snapshot[:credential_fingerprint], config: config) &&
      config.slice(*AUTHORIZATION_FAILURE_CONFIG_KEYS) == snapshot[:authorization_state] &&
      authorization_error_count == snapshot[:authorization_error_count] &&
      ::Redis::Alfred.get(reauthorization_required_key).present? == snapshot[:base_reauthorization_required]
  end

  def authorization_error!
    count = with_durable_reauthorization_lock do
      ::Redis::Alfred.incr(authorization_error_count_key)
    end
    prompt_reauthorization_after_authorization_error! if count >= self.class::AUTHORIZATION_ERROR_THRESHOLD
  end

  def reauthorized!
    with_durable_reauthorization_lock do
      reauthorization_was_required = reauthorization_required?
      restore_base_reauthorization_claim! if reauthorization_was_required
      persist_durable_reauthorization!(false)
      super
    rescue StandardError
      persist_durable_reauthorization!(true) if reauthorization_was_required
      raise
    end
  end

  def record_provider_authorization_error_if_current!(payload, expected_credential_fingerprint:)
    error_payload = self.class.provider_authorization_error(payload)
    return false unless error_payload
    return false unless provider_credential_fingerprint_matches?(expected_credential_fingerprint)
    return false if provider_authorization_healthy_after_error?

    persist_provider_authorization_error_if_current!(error_payload, expected_credential_fingerprint)
  end

  private

  def provider_credential_fingerprint_matches?(expected_fingerprint, config: provider_config.to_h)
    return true if expected_fingerprint.blank?

    credential_identity = [config['business_account_id'], config['api_key']]
    Digest::SHA256.hexdigest(credential_identity.map(&:to_s).join("\0")) == expected_fingerprint
  end

  def persist_provider_authorization_error_if_current!(error_payload, expected_fingerprint)
    safe_error_payload = sanitize_provider_metadata(error_payload)
    with_durable_reauthorization_lock do
      reload
      already_requires_reauthorization = reauthorization_required?
      applied = persist_provider_authorization_error_state_if_current!(safe_error_payload, expected_fingerprint)
      next false unless applied

      prompt_reauthorization! unless already_requires_reauthorization
      true
    end
  end

  def persist_provider_authorization_error_state_if_current!(safe_error_payload, expected_fingerprint)
    with_lock do
      reload
      config = provider_config.to_h.deep_dup
      next false unless provider_credential_fingerprint_matches?(expected_fingerprint, config: config)

      persist_provider_config_state!(
        config.merge(
          'authorization_status' => 'reauthorization_required',
          'authorization_error' => safe_error_payload
        )
      )
      true
    end
  end

  def with_durable_reauthorization_lock(&)
    Whatsapp::WabaLock.new("channel-reauthorization-#{id}").with_lock(&)
  end

  def restore_base_reauthorization_claim!
    ::Redis::Alfred.set(reauthorization_required_key, true, nx: true)
  end

  def persist_durable_reauthorization!(required)
    with_lock do
      reload
      config = provider_config.to_h.deep_dup
      current = ActiveModel::Type::Boolean.new.cast(config[self.class::DURABLE_REAUTHORIZATION_CONFIG_KEY])
      next false if current == required

      update_durable_reauthorization_config(config, required)
      # Provider/network validation must never gate persistence of the recovery anchor.
      # rubocop:disable Rails/SkipsModelValidations
      update_columns(provider_config: config, updated_at: Time.current)
      # rubocop:enable Rails/SkipsModelValidations
    end
  end

  def update_durable_reauthorization_config(config, required)
    if required
      config[self.class::DURABLE_REAUTHORIZATION_CONFIG_KEY] = true
    else
      config.delete(self.class::DURABLE_REAUTHORIZATION_CONFIG_KEY)
    end
  end
end
