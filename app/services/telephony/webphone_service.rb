class Telephony::WebphoneService
  def initialize(account:, bridge_client: nil)
    @account = account
    @bridge_client = bridge_client || Telephony::BridgeClient.new(account_id: account.id)
  end

  def token_for(user:, inbox: nil)
    agent_binding = account.telephony_agent_bindings.find_by(user_id: user.id)
    response = bridge_client.post(
      '/telephony/webphone/token',
      {
        chatwoot_user_id: user.id,
        agent_ref: agent_binding&.agent_ref,
        inbox_id: inbox&.id,
        number_ref: inbox&.telephony_number_binding&.number_ref
      }.compact
    )

    response = response.deep_dup
    response['provider'] ||= inbox&.channel&.provider || agent_binding&.provider || 'fonoster'
    response['agent_ref'] ||= agent_binding&.agent_ref
    response['calling_supported'] = bridge_calling_supported?(response)
    response
  end

  private

  attr_reader :account, :bridge_client

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
