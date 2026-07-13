# frozen_string_literal: true

module WhatsappProviderLifecycle
  extend ActiveSupport::Concern

  def provider_lifecycle_event_recorded?(fingerprint)
    provider_config.to_h.dig(self.class::PROVIDER_LIFECYCLE_CONFIG_KEY, 'fingerprint') == fingerprint
  end

  def store_provider_lifecycle_event!(metadata)
    metadata = sanitize_provider_metadata(metadata)
    stored = false

    mutate_provider_config! do |config|
      current_fingerprint = config.dig(self.class::PROVIDER_LIFECYCLE_CONFIG_KEY, 'fingerprint')
      if metadata['fingerprint'].present? && current_fingerprint == metadata['fingerprint']
        config
      else
        stored = true
        config.merge(self.class::PROVIDER_LIFECYCLE_CONFIG_KEY => metadata)
      end
    end

    stored
  end

  def provider_authorization_reauthorization_recorded?
    provider_authorization_error_recorded?
  end

  def after_provider_authorization_healthy!
    clear_provider_authorization_error!
  end

  private

  def sanitize_provider_metadata(metadata)
    secrets = Meta::CredentialDataSanitizer.channel_secrets(self)
    Meta::CredentialDataSanitizer.sanitize(metadata.to_h.deep_stringify_keys, secrets: secrets)
  end
end
