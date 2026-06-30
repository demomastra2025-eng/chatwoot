require 'base64'
require 'uri'

class Telephony::WebphoneService
  PROVIDER_MANAGED_EXTERNAL_EXTENSION_KINDS = %w[asterisk_analog sipuni binotel].freeze
  PROVIDER_EXTENSION_MODES = %w[external_extension provider_extension].freeze

  def initialize(account:, bridge_client: nil)
    @account = account
    @bridge_client = bridge_client || Telephony::BridgeClient.new(account_id: account.id)
  end

  def token_for(user:, inbox: nil)
    operator_identity = operator_identity_for(user: user, inbox: inbox)
    return unsupported_webphone_payload(inbox: inbox, reason: 'agent_binding_missing') if operator_identity.blank?
    return unsupported_provider_extension_payload(inbox, operator_identity) if provider_managed_external_extension?(inbox, operator_identity)
    return sipuni_webphone_payload(inbox, operator_identity) if sipuni_webphone?(inbox, operator_identity)

    response = bridge_client.post('/telephony/webphone/token', token_request_payload(user, inbox, operator_identity))

    response = response.deep_dup
    response['provider'] ||= fallback_provider(inbox, operator_identity)
    response['agent_ref'] = operator_identity.agent_ref
    response['browser_join_supported'] = operator_identity.browser_join_supported?
    apply_operator_identity(response, operator_identity)
    apply_signaling_server_override(response)
    diagnostics = token_identity_diagnostics(response)
    response['diagnostics'] = response_diagnostics(response, diagnostics)
    response['calling_supported'] = operator_identity_usable?(operator_identity) &&
                                    operator_identity.browser_join_supported? &&
                                    bridge_calling_supported?(response) &&
                                    !diagnostics['token_identity_mismatch']
    response
  end

  def update_presence!(user:, registered:, inbox: nil)
    operator_identity = operator_identity_for(user: user, inbox: inbox)
    return unsupported_webphone_payload(inbox: inbox, reason: 'agent_binding_missing') if operator_identity.blank?

    operator_identity.record.update_browser_registration!(registered: registered)
    operator_identity.record.to_telephony_h.merge(
      provider: fallback_provider(inbox, operator_identity),
      calling_supported: operator_identity.enabled? && operator_identity.browser_join_supported?,
      registered_for_routing: operator_identity.record.registered_for_routing?
    )
  end

  private

  attr_reader :account, :bridge_client

  def token_request_payload(user, inbox, operator_identity)
    {
      chatwoot_user_id: user.id,
      agent_ref: operator_identity&.agent_ref,
      agent_aor: operator_identity&.agent_aor,
      inbox_id: inbox&.id,
      number_ref: inbox&.telephony_number_binding&.number_ref
    }.compact
  end

  def fallback_provider(inbox, operator_identity)
    return 'fonoster' if whatsapp_calling_inbox?(inbox)

    inbox&.channel&.provider || operator_identity&.provider || 'fonoster'
  end

  def whatsapp_calling_inbox?(inbox)
    channel = inbox&.channel
    channel.is_a?(Channel::Whatsapp) && channel.voice_enabled?
  end

  def unsupported_webphone_payload(reason:, inbox: nil)
    {
      provider: fallback_provider(inbox, nil),
      calling_supported: false,
      registered: false,
      registered_for_routing: false,
      reason: reason
    }
  end

  def unsupported_provider_extension_payload(inbox, operator_identity)
    unsupported_webphone_payload(inbox: inbox, reason: 'provider_managed_external_extension').merge(
      agent_ref: operator_identity.agent_ref,
      browser_join_supported: false,
      registered_for_routing: operator_identity.record.respond_to?(:registered_for_routing?) && operator_identity.record.registered_for_routing?
    )
  end

  def operator_identity_usable?(operator_identity)
    operator_identity.present? && operator_identity.enabled?
  end

  def provider_managed_external_extension?(inbox, operator_identity)
    profile = operator_identity&.sip_profile
    return false if profile.blank?
    return false unless PROVIDER_EXTENSION_MODES.include?(profile.availability_mode.to_s)

    PROVIDER_MANAGED_EXTERNAL_EXTENSION_KINDS.include?(provider_kind_for(inbox))
  end

  def sipuni_webphone?(inbox, operator_identity)
    profile = operator_identity&.sip_profile
    return false if profile.blank?
    return false unless profile.availability_mode == 'browser_webphone'

    return inbox.channel.provider == 'sipuni' if inbox.present?

    profile.inbox&.channel&.provider == 'sipuni'
  end

  def sipuni_webphone_payload(inbox, operator_identity)
    profile = operator_identity.sip_profile
    credentials = sipuni_credentials_for(profile)
    janus_server = sipuni_janus_server_url
    missing = []
    missing << 'janus_server' if janus_server.blank?
    missing << 'sip_username' if credentials[:username].blank?
    missing << 'sip_password' if credentials[:password].blank?
    missing << 'sip_host' if credentials[:host].blank?
    supported = missing.blank? && operator_identity.enabled? && operator_identity.browser_join_supported?

    payload = {
      provider: 'sipuni',
      calling_supported: supported,
      callingSupported: supported,
      browser_join_supported: operator_identity.browser_join_supported?,
      browserJoinSupported: operator_identity.browser_join_supported?,
      registered: profile.registered_for_routing?,
      registered_for_routing: profile.registered_for_routing?,
      janus_server: janus_server,
      janusServer: janus_server,
      ice_servers: sipuni_ice_servers,
      iceServers: sipuni_ice_servers,
      agent_ref: operator_identity.agent_ref,
      agent_aor: operator_identity.agent_aor,
      internal_extension: profile.internal_extension,
      internalExtension: profile.internal_extension,
      external_number: inbox&.channel&.phone_number,
      externalNumber: inbox&.channel&.phone_number,
      reason: supported ? nil : sipuni_unsupported_reason(missing),
      sip: sipuni_sip_contract(credentials, profile)
    }.compact

    payload.merge(sipuni_flat_contract(payload[:sip]))
  end

  def sipuni_credentials_for(profile)
    provider_connection = profile.provider_connection
    host = provider_connection&.host.presence || profile.sip_host.presence
    port = provider_connection&.port.presence || 5060
    transport = provider_connection&.transport.presence || 'udp'
    username = profile.sip_username.presence || provider_connection&.username

    {
      username: username,
      password: profile.sip_password,
      host: host,
      port: port,
      transport: transport
    }
  end

  def sipuni_sip_contract(credentials, profile)
    host = credentials[:host]
    username = credentials[:username]
    uri = sip_uri(username, host)
    proxy = sip_proxy_uri(host, credentials[:port], credentials[:transport])

    {
      username: username,
      auth_username: username,
      authUsername: username,
      password: credentials[:password],
      host: host,
      port: credentials[:port],
      transport: credentials[:transport],
      uri: uri,
      proxy: proxy,
      internal_extension: profile.internal_extension,
      internalExtension: profile.internal_extension,
      display_name: profile.user&.name,
      displayName: profile.user&.name
    }.compact
  end

  def sipuni_flat_contract(sip)
    return {} if sip.blank?

    {
      sipUsername: sip[:username],
      sip_username: sip[:username],
      sipPassword: sip[:password],
      sip_password: sip[:password],
      sipHost: sip[:host],
      sip_host: sip[:host],
      sipPort: sip[:port],
      sip_port: sip[:port],
      sipTransport: sip[:transport],
      sip_transport: sip[:transport],
      sipUri: sip[:uri],
      sip_uri: sip[:uri],
      sipProxy: sip[:proxy],
      sip_proxy: sip[:proxy]
    }.compact
  end

  def sip_uri(username, host)
    return if username.blank? || host.blank?

    "sip:#{username}@#{host}"
  end

  def sip_proxy_uri(host, port, transport)
    return if host.blank?

    uri = "sip:#{host}"
    uri = "#{uri}:#{port}" if port.present?
    transport = transport.to_s.downcase
    uri = "#{uri};transport=#{transport}" if transport.in?(%w[tcp tls])
    uri
  end

  def sipuni_janus_server_url
    explicit = ENV.fetch('TELEPHONY_JANUS_WS_URL', '').presence ||
               ENV.fetch('JANUS_PUBLIC_WS_URL', '').presence
    return explicit if explicit.present?

    frontend_url = ENV.fetch('FRONTEND_URL', '').presence
    return if frontend_url.blank?

    uri = URI.parse(frontend_url)
    scheme = uri.scheme == 'http' ? 'ws' : 'wss'
    "#{scheme}://#{uri.host}#{":#{uri.port}" if uri.port && ![80, 443].include?(uri.port)}/janus-sipuni"
  rescue URI::InvalidURIError
    nil
  end

  def sipuni_ice_servers
    raw = ENV.fetch('TELEPHONY_JANUS_ICE_SERVERS_JSON', '').presence
    return [] if raw.blank?

    raw = raw.to_s.strip
    raw = raw[1...-1] if quoted_json_env_value?(raw)
    value = JSON.parse(raw)
    value.is_a?(Array) ? value : []
  rescue JSON::ParserError
    []
  end

  def quoted_json_env_value?(value)
    value.length >= 2 &&
      ((value.start_with?("'") && value.end_with?("'")) ||
        (value.start_with?('"') && value.end_with?('"')))
  end

  def sipuni_unsupported_reason(missing)
    return 'sipuni_webphone_not_configured' if missing.blank?

    "#{missing.join('_')}_missing"
  end

  def provider_kind_for(inbox)
    channel = inbox&.channel
    config = if channel.respond_to?(:provider_config_hash)
               channel.provider_config_hash
             else
               channel&.provider_config
             end

    config.to_h.with_indifferent_access[:provider_kind].to_s
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

  def apply_operator_identity(response, operator_identity)
    return unless apply_operator_identity?(response, operator_identity)

    username, domain = sip_aor_parts(operator_identity.agent_aor)
    response['username'] = username if username.present?
    response['domain'] = domain if domain.present?
    response['targetAor'] = operator_identity.agent_aor
    response.delete('target_aor')
    response.delete(:target_aor)
    response.delete('aor')
    response.delete(:aor)
  end

  def apply_operator_identity?(response, operator_identity)
    return false if operator_identity&.agent_aor.blank?

    provider = response_value(response, 'provider').presence || operator_identity.provider
    provider == 'fonoster' &&
      (operator_identity.sip_profile.present? || bridge_identity_needs_binding_fallback?(response))
  end

  def operator_identity_for(user:, inbox:)
    Telephony::OperatorIdentityResolver.new(account: account, inbox: inbox, user: user).resolve
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
