module Whatsapp::DurableReauthorization
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

  private

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
