class Telephony::ReadinessService
  JANUS_SIP_PROVIDERS = %w[asterisk_analog sipuni binotel].freeze

  def initialize(account:)
    @account = account
  end

  def summary
    inboxes = janus_sip_inboxes.map { |inbox| build_inbox_payload(inbox) }
    {
      ready: inboxes.present? && inboxes.all? { |inbox| inbox[:ready] },
      janus_sip: build_janus_sip_payload(inboxes),
      account: build_account_payload(inboxes),
      inboxes: inboxes,
      warnings: build_account_warnings(inboxes)
    }
  end

  private

  attr_reader :account

  def janus_sip_inboxes
    @janus_sip_inboxes ||= account.inboxes.includes(:channel, telephony_number_binding: :routing_policy).select do |inbox|
      channel = inbox.channel
      channel.is_a?(Channel::Voice) && channel.provider.in?(JANUS_SIP_PROVIDERS)
    end
  end

  def build_janus_sip_payload(inboxes)
    {
      configured: ENV.fetch('TELEPHONY_JANUS_WS_URL', '').present? || ENV.fetch('JANUS_PUBLIC_WS_URL', '').present?,
      healthy: inboxes.present? && inboxes.all? { |inbox| inbox[:ready] },
      providers: JANUS_SIP_PROVIDERS,
      mode: 'browser_webphone'
    }
  end

  def build_account_payload(inboxes)
    {
      feature_enabled: account.feature_enabled?('channel_voice'),
      janus_sip_inboxes_count: inboxes.size,
      ready_inboxes_count: inboxes.count { |inbox| inbox[:ready] },
      number_bindings_count: account.telephony_number_bindings.where(provider: JANUS_SIP_PROVIDERS).count,
      sip_profiles_count: account.telephony_sip_profiles.joins(:inbox).where(inboxes: { id: janus_sip_inboxes.map(&:id) }).count,
      enabled_browser_sip_profiles_count: account.telephony_sip_profiles.joins(:inbox).where(
        inboxes: { id: janus_sip_inboxes.map(&:id) },
        enabled: true,
        availability_mode: 'browser_webphone'
      ).count
    }
  end

  def build_account_warnings(inboxes)
    [].tap do |warnings|
      warnings << warning('no_janus_sip_inboxes', 'No Janus SIP voice inboxes are configured for this account') if inboxes.empty?
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

  def unready_inboxes_warning(inboxes)
    unready_count = inboxes.count { |inbox| !inbox[:ready] }
    return [] unless unready_count.positive?

    [warning('inboxes_not_ready', "#{unready_count} Janus SIP inboxes have blocking warnings")]
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
    return if binding.provider.in?(JANUS_SIP_PROVIDERS)

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

  def bridge_mode_downgrade_warning(_policy)
    nil
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
