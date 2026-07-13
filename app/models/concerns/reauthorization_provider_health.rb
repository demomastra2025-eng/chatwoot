# frozen_string_literal: true

module ReauthorizationProviderHealth
  extend ActiveSupport::Concern

  private

  def provider_authorization_healthy_after_error?
    return false unless respond_to?(:provider_authorization_healthy?)

    reset_provider_authorization_health_cache!
    provider_auth_reauthorization = provider_authorization_reauthorization?
    provider_healthy = provider_authorization_healthy?
    return suppress_transient_provider_failure! if transient_provider_failure?(provider_healthy)
    return false unless provider_healthy
    return preserve_unrelated_reauthorization_after_healthy_check! unless provider_auth_reauthorization

    after_provider_authorization_healthy! if respond_to?(:after_provider_authorization_healthy!)
    Rails.logger.info("[REAUTHORIZATION] Skipping reconnect prompt for #{self.class.name}##{id}: provider health-check passed")
    reauthorized!
    true
  rescue StandardError => e
    Rails.logger.warn(
      "[REAUTHORIZATION] Provider health-check failed for #{self.class.name}##{id}: #{e.class}: #{safe_provider_health_error(e)}"
    )
    false
  ensure
    reset_provider_authorization_health_cache!
  end

  def safe_provider_health_error(error)
    secrets = Meta::CredentialDataSanitizer.channel_secrets(self)
    Meta::CredentialDataSanitizer.sanitize(error.message.to_s.first(500), secrets: secrets)
  end

  def reset_provider_authorization_health_cache!
    remove_instance_variable(:@provider_authorization_health_service) if instance_variable_defined?(:@provider_authorization_health_service)
  end

  def transient_provider_failure?(provider_healthy)
    !provider_healthy && respond_to?(:provider_authorization_transient_failure?) && provider_authorization_transient_failure?
  end

  def suppress_transient_provider_failure!
    ::Redis::Alfred.delete(authorization_error_count_key)
    Rails.logger.info("[REAUTHORIZATION] Skipping reconnect prompt for #{self.class.name}##{id}: transient provider failure")
    true
  end

  def provider_authorization_reauthorization?
    return true unless respond_to?(:provider_authorization_reauthorization_recorded?)

    !reauthorization_required? || provider_authorization_reauthorization_recorded?
  end

  def preserve_unrelated_reauthorization_after_healthy_check!
    ::Redis::Alfred.delete(authorization_error_count_key)
    Rails.logger.info("[REAUTHORIZATION] #{self.class.name}##{id}: provider healthy; keeping existing non-provider reauth flag")
    true
  end
end
