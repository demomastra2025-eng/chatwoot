module Meta::WhatsappAuthorizationHealthHelpers
  MINIMUM_WHATSAPP_GRAPH_VERSION = 25
  WHATSAPP_EMBEDDED_SIGNUP_CONFIG_KEYS = %w[
    WHATSAPP_APP_ID
    WHATSAPP_APP_SECRET
    WHATSAPP_CONFIGURATION_ID
    WHATSAPP_WEBHOOK_VERIFY_TOKEN
  ].freeze

  private

  def whatsapp_configuration_result(identity, version)
    major_version = version.to_s.delete_prefix('v').split('.').first.to_i
    return stale_graph_version_result(identity, version) if major_version < MINIMUM_WHATSAPP_GRAPH_VERSION

    missing_config = WHATSAPP_EMBEDDED_SIGNUP_CONFIG_KEYS.reject { |key| GlobalConfigService.load(key, nil).present? }
    return missing_embedded_signup_result(identity, missing_config) if missing_config.present?

    healthy_result(metadata: identity.metadata.merge('graph_version' => version.to_s, 'embedded_signup_version' => 'v4'))
  end

  def stale_graph_version_result(identity, version)
    degraded_result(
      'graph_version_stale',
      metadata: identity.metadata.merge('configured_version' => version.to_s, 'minimum_version' => 'v25.0')
    )
  end

  def missing_embedded_signup_result(identity, missing_config)
    degraded_result(
      'embedded_signup_configuration_missing',
      metadata: identity.metadata.merge('missing_config' => missing_config, 'required_embedded_signup_version' => 'v4')
    )
  end
end
