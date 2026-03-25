class Telephony::RoutingService
  def initialize(account:, bridge_client: Telephony::BridgeClient.new)
    @account = account
    @bridge_client = bridge_client
  end

  def capabilities
    bridge_client.get('/telephony/capabilities')
  end

  def resources_summary
    bridge_client.get('/telephony/resources/summary')
  end

  def applications
    bridge_client.get('/telephony/applications')
  end

  def numbers
    bridge_client.get('/telephony/numbers')
  end

  def number(number_ref)
    bridge_client.get("/telephony/numbers/#{number_ref}")
  end

  def trunks
    bridge_client.get('/telephony/trunks')
  end

  def agents
    bridge_client.get('/telephony/agents')
  end

  def update_number_route!(number_binding:, attributes:)
    policy = number_binding.routing_policy || number_binding.build_routing_policy(account: account)
    policy.assign_attributes(attributes)
    policy.save!

    response = bridge_client.post("/telephony/numbers/#{number_binding.number_ref}/route", policy.bridge_payload)
    number_binding.update!(
      app_ref: number_binding.app_ref_for_policy(policy),
      last_synced_at: Time.current
    )

    {
      routing_policy: policy,
      response: response
    }
  end

  def toggle_ai!(number_binding:, enabled:, ai_app_ref: nil)
    policy = number_binding.routing_policy || number_binding.build_routing_policy(account: account)
    settings = (policy.settings || {}).deep_dup

    apply_ai_route!(number_binding, policy, settings, enabled: enabled, ai_app_ref: ai_app_ref)
    policy.ai_enabled = enabled
    policy.settings = settings
    policy.save!

    response = bridge_client.post('/telephony/ai/toggle', toggle_ai_payload(number_binding, policy, enabled: enabled))

    number_binding.update!(
      app_ref: number_binding.app_ref_for_policy(policy),
      last_synced_at: Time.current
    )

    {
      routing_policy: policy,
      response: response
    }
  end

  private

  attr_reader :account, :bridge_client

  def toggle_ai_payload(number_binding, policy, enabled:)
    payload = {
      number_ref: number_binding.number_ref,
      enabled: enabled,
      ai_app_ref: policy.ai_app_ref
    }.compact

    return payload if enabled

    payload.merge(number_binding.bridge_fallback_route(policy))
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
    policy.resolved_operator_agent_aor.present?
  end
end
