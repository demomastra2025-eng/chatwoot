class Telephony::ReadinessService
  def initialize(account:, bridge_client: nil)
    @account = account
    @bridge_client = bridge_client || Telephony::BridgeClient.new(account_id: account.id)
  end

  def summary
    inboxes = fonoster_inboxes.map { |inbox| build_inbox_payload(inbox) }
    bridge = build_bridge_payload
    {
      ready: bridge[:healthy] && inboxes.present? && inboxes.all? { |inbox| inbox[:ready] },
      bridge: bridge,
      account: build_account_payload(inboxes),
      inboxes: inboxes,
      warnings: build_account_warnings(bridge, inboxes)
    }
  end

  private

  attr_reader :account, :bridge_client

  def fonoster_inboxes
    @fonoster_inboxes ||= account.inboxes.includes(:channel, telephony_number_binding: :routing_policy).select do |inbox|
      channel = inbox.channel
      channel.is_a?(Channel::Voice) && channel.provider == 'fonoster'
    end
  end

  def build_bridge_payload
    health = bridge_client.get('/healthz')
    checks = bridge_checks(health)
    {
      configured: bridge_configured?,
      reachable: true,
      healthy: checks.values.all?,
      response_kind: health.is_a?(Hash) ? 'json' : 'non_json',
      service: health.is_a?(Hash) ? health['service'] : nil,
      checks: checks
    }.compact
  rescue Telephony::Error => e
    {
      configured: bridge_configured?,
      reachable: false,
      healthy: false,
      error_code: e.code,
      error: e.message
    }
  end

  def bridge_checks(health)
    return unsuccessful_bridge_checks unless health.is_a?(Hash)

    {
      healthz_ok: health['ok'] == true,
      bridge_service: health['service'] == 'telephony-bridge',
      fonoster_reachable: health.dig('fonoster', 'applicationsReachable') == true,
      onelink_callback_configured: health.dig('legacyChatwootCompatibility', 'configured') == true
    }
  end

  def unsuccessful_bridge_checks
    {
      healthz_ok: false,
      bridge_service: false,
      fonoster_reachable: false,
      onelink_callback_configured: false
    }
  end

  def build_account_payload(inboxes)
    {
      feature_enabled: account.feature_enabled?('channel_voice'),
      fonoster_inboxes_count: inboxes.size,
      ready_inboxes_count: inboxes.count { |inbox| inbox[:ready] },
      number_bindings_count: account.telephony_number_bindings.where(provider: 'fonoster').count,
      agent_bindings_count: account.telephony_agent_bindings.where(provider: 'fonoster').count,
      enabled_agent_bindings_count: account.telephony_agent_bindings.where(provider: 'fonoster', enabled: true).count
    }
  end

  def build_account_warnings(bridge, inboxes)
    bridge_warnings(bridge).tap do |warnings|
      warnings << warning('no_fonoster_inboxes', 'No Fonoster voice inboxes are configured for this account') if inboxes.empty?
      warnings.concat(unready_inboxes_warning(inboxes))
    end
  end

  def build_inbox_payload(inbox)
    channel = inbox.channel
    binding = inbox.telephony_number_binding
    policy = binding&.routing_policy
    virtual_pbx = virtual_pbx_config(inbox)
    warnings = build_inbox_warnings(channel, binding, policy, virtual_pbx)
    {
      id: inbox.id,
      name: inbox.name,
      channel_id: channel&.id,
      phone_number: virtual_pbx&.dig(:phone_numbers, :display_phone_number) || channel&.phone_number || binding&.phone_number,
      provider: channel&.provider || binding&.provider,
      ready: warnings.empty?,
      number_binding_present: binding.present?,
      routing_policy_present: policy.present?,
      last_synced_at: binding&.last_synced_at,
      number_ref: binding&.number_ref,
      route: build_route_payload(binding, policy),
      virtual_pbx: virtual_pbx,
      warnings: warnings
    }.compact
  end

  def build_inbox_warnings(channel, binding, policy, virtual_pbx)
    return [warning('missing_number_binding', 'Telephony number binding is missing')] if binding.blank?

    warnings = binding_warnings(channel, binding, virtual_pbx)
    return warnings + [warning('missing_routing_policy', 'Telephony routing policy is missing')] if policy.blank?

    warnings + build_route_warnings(binding, policy)
  end

  def build_route_payload(binding, policy)
    return unless binding.present? || policy.present?

    {
      mode: policy&.mode,
      bridge_mode: policy&.bridge_mode,
      primary_app_ref: binding&.configured_app_ref,
      effective_app_ref: binding&.app_ref_for_policy(policy),
      ai_app_ref: policy&.ai_app_ref,
      operator_agent_ref: policy&.operator_agent_ref,
      operator_agent_aor: policy&.resolved_operator_agent_aor,
      fallback_mode: policy&.fallback_mode
    }.compact
  end

  def build_route_warnings(binding, policy)
    route_warnings = [
      bridge_mode_downgrade_warning(policy),
      app_route_warning(binding, policy),
      ai_route_warning(policy),
      operator_route_warning(policy)
    ].compact

    route_warnings + fallback_route_warnings(binding, policy)
  end

  def warning(code, message) = { code: code, message: message }

  def bridge_configured? = ENV.fetch('TELEPHONY_BRIDGE_BASE_URL', '').to_s.present?

  def bridge_warnings(bridge)
    [].tap do |warnings|
      warnings << warning('bridge_not_configured', 'Telephony bridge base URL is not configured') unless bridge[:configured]
      warnings << warning('bridge_unreachable', bridge[:error] || 'Telephony bridge is unreachable') if bridge[:configured] && !bridge[:reachable]
      warnings << warning('bridge_unhealthy', 'Telephony bridge health checks are failing') if bridge[:reachable] && !bridge[:healthy]
    end
  end

  def unready_inboxes_warning(inboxes)
    unready_count = inboxes.count { |inbox| !inbox[:ready] }
    return [] unless unready_count.positive?

    [warning('inboxes_not_ready', "#{unready_count} Fonoster inboxes have blocking warnings")]
  end

  def binding_warnings(channel, binding, virtual_pbx)
    [
      (warning('missing_number_ref', 'Telephony number ref is missing') if binding.number_ref.blank?),
      binding_provider_warning(binding),
      (warning('missing_last_synced_at', 'Telephony number binding has never been synced') if binding.last_synced_at.blank?),
      phone_number_mismatch_warning(channel, binding, virtual_pbx)
    ].compact
  end

  def binding_provider_warning(binding)
    return if binding.provider == 'fonoster'

    warning('binding_provider_mismatch', 'Telephony number binding provider does not match inbox provider')
  end

  def phone_number_mismatch_warning(channel, binding, virtual_pbx)
    return if channel&.phone_number.blank?
    return if binding.phone_number.blank?
    return if binding.phone_number == channel.phone_number
    return if virtual_pbx_phone_split_allowed?(virtual_pbx)

    warning('phone_number_mismatch', 'Telephony number binding phone does not match inbox phone')
  end

  def virtual_pbx_phone_split_allowed?(virtual_pbx)
    phone_numbers = virtual_pbx&.dig(:phone_numbers)
    return false if phone_numbers.blank?

    phone_numbers[:split_allowed] &&
      phone_numbers[:display_phone_number].present? &&
      phone_numbers[:ingress_number].present? &&
      phone_numbers[:display_phone_number] != phone_numbers[:ingress_number]
  end

  def virtual_pbx_config(inbox)
    Telephony::VirtualPbx::ConfigBuilder.new(account: account).for_inbox(inbox)
  rescue Telephony::Error, ActiveRecord::RecordNotFound
    nil
  end

  def bridge_mode_downgrade_warning(policy)
    return if policy.mode == policy.bridge_mode

    warning(
      'bridge_mode_downgraded',
      "Stored mode #{policy.mode} is not executable on the bridge and will be sent as #{policy.bridge_mode}"
    )
  end

  def app_route_warning(binding, policy)
    return unless policy.app_mode? && binding.configured_app_ref.blank?

    warning('mode_requires_app_ref', 'App routing requires a configured primary app ref')
  end

  def ai_route_warning(policy)
    return unless policy.ai_mode? && policy.ai_app_ref.blank?

    warning('mode_requires_ai_app_ref', 'AI routing requires ai_app_ref')
  end

  def operator_route_warning(policy)
    return unless policy.operator_mode?
    return unless policy.targeted_operator_distribution?
    return if policy.resolved_operator_agent_aor.present?

    warning('mode_requires_operator_agent', 'Operator routing requires a resolvable operator agent')
  end

  def fallback_route_warnings(binding, policy)
    case policy.fallback_mode
    when 'app'
      return [] if binding.configured_app_ref.present?

      [warning('fallback_requires_app_ref', 'App fallback requires a configured primary app ref')]
    when 'ai'
      return [] if policy.ai_app_ref.present?

      [warning('fallback_requires_ai_app_ref', 'AI fallback requires ai_app_ref')]
    when 'operator'
      return [] unless policy.targeted_operator_distribution?
      return [] if policy.resolved_operator_agent_aor.present?

      [warning('fallback_requires_operator_agent', 'Operator fallback requires a resolvable operator agent')]
    else
      []
    end
  end
end
