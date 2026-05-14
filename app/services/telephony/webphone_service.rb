require 'base64'

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
    apply_agent_binding_identity(response, agent_binding)
    apply_signaling_server_override(response)
    diagnostics = token_identity_diagnostics(response)
    response['diagnostics'] = response_diagnostics(response, diagnostics)
    response['calling_supported'] = agent_binding_usable?(agent_binding) &&
                                    bridge_calling_supported?(response) &&
                                    !diagnostics['token_identity_mismatch']
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
      agent_aor: agent_binding&.agent_aor,
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

  def apply_agent_binding_identity(response, agent_binding)
    return unless apply_agent_binding_identity?(response, agent_binding)

    username, domain = sip_aor_parts(agent_binding.agent_aor)
    response['username'] = username if username.present?
    response['domain'] = domain if domain.present?
    response['targetAor'] = agent_binding.agent_aor
    response.delete('target_aor')
    response.delete(:target_aor)
    response.delete('aor')
    response.delete(:aor)
  end

  def apply_agent_binding_identity?(response, agent_binding)
    return false if agent_binding&.agent_aor.blank?

    provider = response_value(response, 'provider').presence || agent_binding.provider
    provider == 'fonoster' && bridge_identity_needs_binding_fallback?(response)
  end

  def bridge_identity_needs_binding_fallback?(response)
    target_aor = response_value(response, 'targetAor', 'target_aor', 'aor').to_s.strip
    username = response_value(response, 'username').to_s.strip
    domain = response_value(response, 'domain').to_s.strip

    target_aor.blank? ||
      target_aor == 'sip:voice@default' ||
      username.blank? ||
      username == 'internal' ||
      domain.blank? ||
      domain == 'internal'
  end

  def sip_aor_parts(agent_aor)
    agent_aor.to_s.sub(/\Asip:/i, '').split('@', 2)
  end

  def response_diagnostics(response, token_diagnostics)
    diagnostics = response['diagnostics'].is_a?(Hash) ? response['diagnostics'].deep_dup : {}
    diagnostics.merge(token_diagnostics).compact
  end

  def token_identity_diagnostics(response)
    claims = decoded_token_claims(response_value(response, 'token'))
    return {} if claims.blank?

    expected = expected_token_identity(response)
    actual = actual_token_identity(claims)
    mismatch = expected.any? { |key, value| value.present? && actual[key].present? && actual[key] != value }
    mismatch ||= token_test_grade_identity?(actual)

    return {} unless mismatch

    {
      'token_identity_mismatch' => true,
      'expected_token_identity' => expected.compact,
      'actual_token_identity' => actual.compact
    }
  end

  def decoded_token_claims(token)
    parts = token.to_s.split('.')
    return {} unless parts.length >= 2

    payload = parts[1]
    payload += '=' * ((4 - (payload.length % 4)) % 4)
    JSON.parse(Base64.urlsafe_decode64(payload))
  rescue ArgumentError, JSON::ParserError
    {}
  end

  def expected_token_identity(response)
    {
      'username' => response_value(response, 'username').to_s.presence,
      'domain' => response_value(response, 'domain').to_s.presence,
      'targetAor' => response_value(response, 'targetAor', 'target_aor', 'aor').to_s.presence
    }
  end

  def actual_token_identity(claims)
    {
      'username' => claims['username'].to_s.presence,
      'domain' => claims['domain'].to_s.presence,
      'targetAor' => claims['targetAor'].to_s.presence || claims['target_aor'].to_s.presence,
      'aorLink' => claims['aorLink'].to_s.presence || claims['aor_link'].to_s.presence,
      'allowedMethods' => Array.wrap(claims['allowedMethods'] || claims['allowed_methods'])
    }
  end

  def token_test_grade_identity?(identity)
    identity['username'] == 'internal' ||
      identity['domain'] == 'internal' ||
      identity['targetAor'] == 'sip:voice@default' ||
      identity['aorLink'] == 'sip:voice@default'
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
