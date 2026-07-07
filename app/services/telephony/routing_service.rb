class Telephony::RoutingService
  JANUS_SIP_PROVIDERS = %w[asterisk_analog sipuni binotel].freeze
  ROUTE_CONFIG_KEYS = {
    mode: :routing_mode,
    app_ref: :app_route_app_ref,
    ai_app_ref: :ai_app_ref,
    ai_deployment_mode: :ai_deployment_mode,
    onelink_ai_app_ref: :onelink_ai_app_ref,
    fallback_ai_app_ref: :fallback_ai_app_ref,
    captain_assistant_id: :captain_assistant_id,
    ai_voice_settings: :ai_voice_settings,
    operator_agent_ref: :operator_agent_ref,
    operator_agent_aor: :operator_agent_aor,
    operator_distribution_mode: :operator_distribution_mode,
    fallback_mode: :fallback_mode,
    fallback_message: :fallback_message
  }.freeze

  def initialize(account:)
    @account = account
  end

  def capabilities
    {
      provider: 'janus_sip',
      providers: JANUS_SIP_PROVIDERS,
      browser_calling: true,
      remote_bridge: false
    }
  end

  def resources_summary
    {
      provider: 'janus_sip',
      remote_bridge: false,
      numbers_count: account.telephony_number_bindings.count,
      sip_profiles_count: account.telephony_sip_profiles.count,
      voice_inboxes_count: janus_voice_inboxes.count
    }
  end

  def applications
    []
  end

  def numbers
    account.telephony_number_bindings.recent.map(&:to_telephony_h)
  end

  def number(number_ref)
    account.telephony_number_bindings.find_by!(number_ref: number_ref).to_telephony_h
  end

  def trunks
    []
  end

  def agents
    account.telephony_sip_profiles.includes(:user, :provider_connection).recent.map(&:to_telephony_h)
  end

  def update_number_route!(number_binding:, attributes:)
    attributes = normalized_route_attributes(attributes)
    sync_voice_channel_route_config!(number_binding, attributes)

    policy = number_binding.routing_policy || number_binding.build_routing_policy(account: account)
    policy.assign_attributes(policy_attributes(attributes, policy))
    policy.save!

    number_binding.update!(
      app_ref: number_binding.runtime_app_ref,
      last_synced_at: Time.current
    )

    {
      routing_policy: policy,
      response: local_sync_response(number_binding)
    }
  end

  def toggle_ai!(number_binding:, enabled:, ai_app_ref: nil)
    policy = number_binding.routing_policy || number_binding.build_routing_policy(account: account)
    settings = (policy.settings || {}).deep_dup

    apply_ai_route!(number_binding, policy, settings, enabled: enabled, ai_app_ref: ai_app_ref)
    policy.ai_enabled = enabled
    policy.settings = settings
    policy.save!

    number_binding.update!(
      app_ref: number_binding.runtime_app_ref,
      last_synced_at: Time.current
    )

    {
      routing_policy: policy,
      response: local_sync_response(number_binding, ai_enabled: enabled)
    }
  end

  private

  attr_reader :account

  def janus_voice_inboxes
    account.inboxes.where(channel_type: 'Channel::Voice').includes(:channel).select do |inbox|
      inbox.channel&.provider.in?(JANUS_SIP_PROVIDERS)
    end
  end

  def normalized_route_attributes(attributes)
    attributes.to_h.with_indifferent_access
  end

  def policy_attributes(attributes, policy)
    base_attributes = attributes.except(:app_ref, :operator_distribution_mode)
    return base_attributes unless attributes.key?(:operator_distribution_mode)

    settings = (policy.settings || {}).deep_stringify_keys
    settings['operator_distribution_mode'] = Telephony::RoutingPolicy.normalized_operator_distribution_mode(
      attributes[:operator_distribution_mode]
    )
    base_attributes.merge(settings: settings)
  end

  def sync_voice_channel_route_config!(number_binding, attributes)
    channel = number_binding.voice_channel
    return unless channel&.provider.in?(JANUS_SIP_PROVIDERS)

    config = channel.provider_config_hash.with_indifferent_access
    ROUTE_CONFIG_KEYS.each do |attribute_key, config_key|
      next unless attributes.key?(attribute_key)

      value = route_config_value(attribute_key, attributes[attribute_key])
      value.present? ? config[config_key] = value : config.delete(config_key)
    end

    channel.update!(provider_config: config.to_h)
    number_binding.reload
  end

  def route_config_value(attribute_key, value)
    return value.to_h.deep_stringify_keys if attribute_key == :ai_voice_settings && value.respond_to?(:to_h)

    normalized_value = value.to_s.strip.presence
    return normalized_value unless attribute_key == :mode && normalized_value.present?

    Telephony::RoutingPolicy::BRIDGE_SUPPORTED_MODES.include?(normalized_value) ? normalized_value : 'reject'
  end

  def apply_ai_route!(number_binding, policy, settings, enabled:, ai_app_ref:)
    if enabled
      enable_ai_route!(policy, settings, ai_app_ref)
    else
      disable_ai_route!(number_binding, policy, settings)
    end
  end

  def enable_ai_route!(policy, settings, ai_app_ref)
    settings['last_non_ai_mode'] = policy.mode unless policy.mode == 'ai'
    policy.mode = 'ai'
    policy.ai_app_ref = ai_app_ref.presence || policy.ai_app_ref
  end

  def disable_ai_route!(number_binding, policy, settings)
    restore_mode = settings['last_non_ai_mode'].presence || default_restore_mode(number_binding, policy)
    policy.mode = normalize_restore_mode(number_binding, policy, restore_mode)
  end

  def default_restore_mode(number_binding, policy)
    return 'operator' if operator_route_configured?(policy)
    return 'app' if number_binding.configured_app_ref.present?

    'reject'
  end

  def normalize_restore_mode(number_binding, policy, restore_mode)
    requested_mode = restore_mode.to_s.strip.downcase

    case requested_mode
    when 'operator'
      return 'operator' if operator_route_configured?(policy)
    when 'app'
      return 'app' if number_binding.configured_app_ref.present?
    when 'reject'
      return 'reject'
    end

    default_restore_mode(number_binding, policy)
  end

  def operator_route_configured?(policy)
    return false if policy.blank?
    return true unless policy.targeted_operator_distribution?

    policy.resolved_operator_agent_aor.to_s.downcase.start_with?('sip:')
  end

  def local_sync_response(number_binding, ai_enabled: nil)
    {
      'provider' => 'janus_sip',
      'remote_bridge' => false,
      'number_ref' => number_binding.number_ref,
      'ai_enabled' => ai_enabled
    }.compact
  end
end
