class Telephony::WebphoneService
  def initialize(account:, bridge_client: nil)
    @account = account
    @bridge_client = bridge_client || Telephony::BridgeClient.new(account_id: account.id)
  end

  def token_for(user:, inbox: nil)
    agent_binding = account.telephony_agent_bindings.find_by(user_id: user.id)
    response = bridge_client.post('/telephony/webphone/token', token_request_payload(user, inbox, agent_binding))

    response = response.deep_dup
    response['provider'] ||= fallback_provider(inbox, agent_binding)
    response['agent_ref'] ||= agent_binding&.agent_ref
    apply_signaling_server_override(response)
    response['calling_supported'] = agent_binding_usable?(agent_binding) && bridge_calling_supported?(response)
    response
  end

  def update_presence!(user:, registered:)
    agent_binding = account.telephony_agent_bindings.find_by!(user_id: user.id)
    agent_binding.update_browser_registration!(registered: registered)
    agent_binding.to_telephony_h.merge(registered_for_routing: agent_binding.registered_for_routing?)
  end

  private

  attr_reader :account, :bridge_client

  def token_request_payload(user, inbox, agent_binding)
    {
      chatwoot_user_id: user.id,
      agent_ref: agent_binding&.agent_ref,
      inbox_id: inbox&.id,
      number_ref: inbox&.telephony_number_binding&.number_ref
    }.compact
  end

  def fallback_provider(inbox, agent_binding)
    inbox&.channel&.provider || agent_binding&.provider || 'fonoster'
  end

  def agent_binding_usable?(agent_binding)
    agent_binding.present? && agent_binding.enabled?
  end

  def apply_signaling_server_override(response)
    signaling_server_url = ENV.fetch('TELEPHONY_WEBPHONE_SIGNALING_SERVER_URL', '').presence
    return if signaling_server_url.blank?

    provider = response_value(response, 'provider').presence || 'fonoster'
    return unless provider == 'fonoster'

    response['signalingServer'] = signaling_server_url
    response.delete('signaling_server')
    response.delete(:signaling_server)
  end

  def bridge_calling_supported?(response)
    provider = response_value(response, 'provider').presence || 'fonoster'
    return fonoster_browser_calling_supported?(response) if provider == 'fonoster'

    calling_supported = response_value(response, 'calling_supported', 'callingSupported')
    return calling_supported unless calling_supported.nil?

    provider == 'twilio'
  end

  def fonoster_browser_calling_supported?(response)
    calling_supported = response_value(response, 'calling_supported', 'callingSupported')
    return false if calling_supported == false

    required_values_present?(
      response,
      %w[token username domain],
      %w[signalingServer signaling_server],
      %w[targetAor target_aor aor]
    )
  end

  def required_values_present?(response, required_keys, *alternative_key_groups)
    required_keys.all? { |key| response_value(response, key).present? } &&
      alternative_key_groups.all? do |group|
        group.any? { |key| response_value(response, key).present? }
      end
  end

  def response_value(response, *keys)
    keys.each do |key|
      return response[key] if response.key?(key)

      symbol_key = key.to_sym
      return response[symbol_key] if response.key?(symbol_key)
    end

    nil
  end
end
