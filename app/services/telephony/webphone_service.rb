require 'base64'
require 'uri'

class Telephony::WebphoneService
  PROVIDER_MANAGED_EXTERNAL_EXTENSION_KINDS = %w[asterisk_analog sipuni binotel].freeze
  PROVIDER_EXTENSION_MODES = %w[external_extension provider_extension].freeze
  JANUS_SIP_WEBPHONE_PROVIDERS = %w[asterisk_analog sipuni binotel].freeze
  BROWSER_SIP_INCOMING_SOURCE = 'browser_janus_sip'.freeze

  def initialize(account:, bridge_client: nil)
    @account = account
    @bridge_client = bridge_client || Telephony::BridgeClient.new(account_id: account.id)
  end

  def token_for(user:, inbox: nil)
    bootstrap_payload = webphone_bootstrap_payload_for(user, inbox)
    return bootstrap_payload if bootstrap_payload.present?

    operator_identity = operator_identity_for(user: user, inbox: inbox)
    return unsupported_webphone_payload(inbox: inbox, reason: 'agent_binding_missing') if operator_identity.blank?

    webphone_payload_for_identity(user, inbox, operator_identity)
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

  def report_browser_sip_incoming!(user:, inbox:, params:)
    provider = browser_sip_incoming_provider!(inbox)
    context = browser_sip_incoming_context(provider: provider, user: user, inbox: inbox, params: params)
    context[:profile].update_browser_registration!(registered: true)

    decision = perform_browser_sip_incoming_route(context)
    call_session = account.telephony_call_sessions.find_by!(external_call_ref: context[:call_ref])
    call_session = persist_browser_sip_incoming_metadata!(call_session, context[:profile], params)

    browser_sip_incoming_payload(call_session, decision, context[:profile])
  end

  private

  attr_reader :account, :bridge_client

  def webphone_bootstrap_payload_for(user, inbox)
    return if inbox.present?

    native_sessions = janus_sip_webphone_payloads_for(user)
    bridge_session = legacy_bridge_webphone_payload_for(user, optional: native_sessions.present?)
    return bridge_session if native_sessions.blank? && bridge_session.present?

    sessions = [bridge_session, *native_sessions].compact
    multi_webphone_payload(sessions) if sessions.present?
  end

  def legacy_bridge_webphone_payload_for(user, optional:)
    binding = account.telephony_agent_bindings.enabled.find_by(user_id: user&.id)
    return if binding.blank?

    operator_identity = Telephony::OperatorIdentityResolver::Identity.new(source: :agent_binding, record: binding)
    bridge_webphone_payload(user, nil, operator_identity)
  rescue StandardError
    raise unless optional

    unsupported_webphone_payload(reason: 'fonoster_webphone_token_failed').merge(
      provider: 'fonoster',
      browser_join_supported: false,
      browserJoinSupported: false
    )
  end

  def webphone_payload_for_identity(user, inbox, operator_identity)
    return unsupported_provider_extension_payload(inbox, operator_identity) if provider_managed_external_extension?(inbox, operator_identity)
    return janus_sip_webphone_payload(inbox, operator_identity) if janus_sip_webphone?(inbox, operator_identity)

    bridge_webphone_payload(user, inbox, operator_identity)
  end

  def bridge_webphone_payload(user, inbox, operator_identity)
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

    inbox_voice_provider(inbox) || operator_identity&.provider || 'fonoster'
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

  def janus_sip_webphone?(inbox, operator_identity)
    profile = operator_identity&.sip_profile
    return false if profile.blank?
    return false unless profile.availability_mode == 'browser_webphone'

    return inbox_voice_provider(inbox).to_s.in?(JANUS_SIP_WEBPHONE_PROVIDERS) if inbox.present?

    inbox_voice_provider(profile.inbox).to_s.in?(JANUS_SIP_WEBPHONE_PROVIDERS)
  end

  def janus_sip_webphone_payload(inbox, operator_identity)
    profile = operator_identity.sip_profile
    provider = janus_sip_provider_for(inbox, profile)
    credentials = janus_sip_credentials_for(profile)
    janus_server = janus_sip_server_url(provider)
    support = janus_sip_support_state(provider, operator_identity, credentials, janus_server)
    sip = janus_sip_contract(credentials, profile)

    payload = janus_sip_base_payload(provider, operator_identity, profile, janus_server, support).merge(
      janus_sip_session_payload(profile)
    ).merge(
      external_number: inbox&.channel&.phone_number,
      externalNumber: inbox&.channel&.phone_number,
      reason: support[:reason],
      sip: sip
    ).compact

    payload.merge(janus_sip_flat_contract(sip))
  end

  def janus_sip_support_state(provider, operator_identity, credentials, janus_server)
    missing = janus_sip_missing_contract_fields(credentials, janus_server)
    supported = missing.blank? && operator_identity.enabled? && operator_identity.browser_join_supported?

    {
      supported: supported,
      reason: supported ? nil : janus_sip_unsupported_reason(missing, provider)
    }
  end

  def janus_sip_missing_contract_fields(credentials, janus_server)
    [].tap do |missing|
      missing << 'janus_server' if janus_server.blank?
      missing << 'sip_username' if credentials[:username].blank?
      missing << 'sip_password' if credentials[:password].blank?
      missing << 'sip_host' if credentials[:host].blank?
    end
  end

  def janus_sip_base_payload(provider, operator_identity, profile, janus_server, support)
    browser_join_supported = operator_identity.browser_join_supported?

    {
      provider: provider,
      calling_supported: support[:supported],
      callingSupported: support[:supported],
      browser_join_supported: browser_join_supported,
      browserJoinSupported: browser_join_supported,
      registered: profile.registered_for_routing?,
      registered_for_routing: profile.registered_for_routing?,
      janus_server: janus_server,
      janusServer: janus_server,
      ice_servers: sipuni_ice_servers,
      iceServers: sipuni_ice_servers,
      agent_ref: operator_identity.agent_ref,
      agent_aor: operator_identity.agent_aor
    }
  end

  def janus_sip_session_payload(profile)
    session_key = janus_sip_session_key(profile)

    {
      session_key: session_key,
      sessionKey: session_key,
      sip_profile_id: profile.id,
      sipProfileId: profile.id,
      inbox_id: profile.inbox_id,
      inboxId: profile.inbox_id,
      provider_connection_id: profile.provider_connection_id,
      providerConnectionId: profile.provider_connection_id,
      internal_extension: profile.internal_extension,
      internalExtension: profile.internal_extension
    }
  end

  def janus_sip_webphone_payloads_for(user)
    return [] if user.blank?

    account.telephony_sip_profiles
           .includes(:inbox, :user, :provider_connection)
           .where(user_id: user.id, enabled: true, availability_mode: 'browser_webphone')
           .where.not(status: %w[disabled deleting failed])
           .order(updated_at: :desc, id: :desc)
           .filter_map do |profile|
      provider = janus_sip_provider_for(profile.inbox, profile)
      next unless provider.to_s.in?(JANUS_SIP_WEBPHONE_PROVIDERS)

      operator_identity = Telephony::OperatorIdentityResolver::Identity.new(source: :sip_profile, record: profile)
      janus_sip_webphone_payload(profile.inbox, operator_identity)
    end
  end

  def multi_webphone_payload(sessions)
    primary = sessions.first.deep_dup
    primary.merge(
      sessions: sessions,
      webphone_sessions: sessions,
      webphoneSessions: sessions,
      multi_session: true,
      multiSession: true,
      calling_supported: sessions.any? { |session| session_calling_supported?(session) },
      callingSupported: sessions.any? { |session| session_calling_supported?(session) }
    )
  end

  def session_calling_supported?(session)
    value = session[:calling_supported] ||
            session['calling_supported'] ||
            session[:callingSupported] ||
            session['callingSupported']
    ActiveModel::Type::Boolean.new.cast(value)
  end

  def janus_sip_session_key(profile)
    return if profile.blank?

    "sip_profile:#{profile.id}"
  end

  def janus_sip_provider_for(inbox, profile)
    inbox_voice_provider(inbox) ||
      inbox_voice_provider(profile&.inbox) ||
      profile&.provider_connection&.provider_kind.presence ||
      'sipuni'
  end

  def inbox_voice_provider(inbox)
    channel = inbox&.channel
    return if channel.blank?

    return unless channel.respond_to?(:provider)

    channel.provider.presence
  end

  def janus_sip_credentials_for(profile)
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

  def janus_sip_contract(credentials, profile)
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

  def janus_sip_flat_contract(sip)
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

  def janus_sip_server_url(provider)
    janus_sip_env_server_url(provider) || janus_sip_frontend_server_url
  end

  def janus_sip_env_server_url(provider)
    provider_key = provider.to_s.upcase
    provider_specific = ENV.fetch("TELEPHONY_#{provider_key}_JANUS_WS_URL", '').presence
    return provider_specific if provider_specific.present?

    ENV.fetch('TELEPHONY_JANUS_WS_URL', '').presence ||
      ENV.fetch('JANUS_PUBLIC_WS_URL', '').presence
  end

  def janus_sip_frontend_server_url
    frontend_url = ENV.fetch('FRONTEND_URL', '').presence
    return if frontend_url.blank?

    uri = URI.parse(frontend_url)
    scheme = uri.scheme == 'http' ? 'ws' : 'wss'
    "#{scheme}://#{uri.host}#{":#{uri.port}" if uri.port && [80, 443].exclude?(uri.port)}/janus-sipuni"
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

  def janus_sip_unsupported_reason(missing, provider)
    provider = provider.to_s.presence || 'sip'
    return "#{provider}_webphone_not_configured" if missing.blank?

    "#{missing.join('_')}_missing"
  end

  def provider_kind_for(inbox)
    channel = inbox&.channel
    config = if channel.respond_to?(:provider_config_hash)
               channel.provider_config_hash
             else
               channel&.provider_config
             end

    config.to_h.with_indifferent_access[:provider_kind].presence || inbox_voice_provider(inbox).to_s
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

  def browser_sip_incoming_provider!(inbox)
    provider = inbox_voice_provider(inbox).to_s
    return provider if provider.in?(JANUS_SIP_WEBPHONE_PROVIDERS)

    raise Telephony::Error.new(code: 'UNSUPPORTED_WEBPHONE_PROVIDER', message: 'Inbox does not use native browser SIP',
                               status: :unprocessable_content)
  end

  def browser_sip_incoming_context(provider:, user:, inbox:, params:)
    profile = browser_sip_incoming_profile!(user, inbox, params)
    {
      provider: provider,
      inbox: inbox,
      params: params,
      profile: profile,
      binding: ensure_voice_number_binding!(inbox),
      call_ref: browser_sip_incoming_call_ref(provider, profile, params)
    }
  end

  def perform_browser_sip_incoming_route(context)
    Telephony::InboundRoutingService.new(
      payload: browser_sip_incoming_route_payload(context)
    ).perform
  end

  def browser_sip_incoming_profile!(user, inbox, params)
    scope = account.telephony_sip_profiles.enabled.where(
      user_id: user&.id,
      inbox_id: inbox.id,
      availability_mode: 'browser_webphone'
    ).where.not(status: %w[disabled deleting failed])

    profile_id = params_value(params, 'sip_profile_id', 'sipProfileId')
    scope = scope.where(id: profile_id) if profile_id.present?

    profile = scope.order(updated_at: :desc, id: :desc).first
    return profile if profile.present?

    raise Telephony::Error.new(code: 'WEBPHONE_SIP_PROFILE_NOT_FOUND', message: 'No browser SIP profile found for this inbox',
                               status: :not_found)
  end

  def ensure_voice_number_binding!(inbox)
    binding = inbox.telephony_number_binding
    binding ||= Telephony::NumberBinding.sync_from_voice_channel!(inbox.channel) if inbox.channel_type == 'Channel::Voice'
    return binding if binding.present?

    raise Telephony::Error.new(code: 'VOICE_INBOX_NOT_BOUND', message: 'Voice inbox is not bound to a telephony number',
                               status: :unprocessable_content)
  end

  def browser_sip_incoming_call_ref(provider, profile, params)
    raw_call_ref = params_value(params, 'call_ref', 'callRef', 'call_sid', 'callSid').to_s.strip
    raise Telephony::Error.new(code: 'CALL_REF_REQUIRED', message: 'call_ref is required', status: :unprocessable_content) if raw_call_ref.blank?

    return raw_call_ref if raw_call_ref.start_with?("#{provider}:")

    "#{provider}:janus:#{profile.id}:#{raw_call_ref}"
  end

  def browser_sip_incoming_route_payload(context)
    inbox = context.fetch(:inbox)
    binding = context.fetch(:binding)
    profile = context.fetch(:profile)
    params = context.fetch(:params)

    {
      account_id: account.id,
      inbox_id: inbox.id,
      number_ref: binding.number_ref,
      provider: context.fetch(:provider),
      direction: 'inbound',
      call_ref: context.fetch(:call_ref),
      caller_number: browser_sip_incoming_from(params),
      ingress_number: browser_sip_incoming_to(params, inbox, binding),
      target_extension: profile.internal_extension,
      target_sip_profile_id: profile.id,
      target_user_id: profile.user_id,
      metadata: browser_sip_incoming_metadata(profile, params)
    }.compact
  end

  def browser_sip_incoming_metadata(profile, params)
    {
      source: BROWSER_SIP_INCOMING_SOURCE,
      janus_call_ref: params_value(params, 'call_ref', 'callRef', 'call_sid', 'callSid'),
      janus_session_key: params_value(params, 'session_key', 'sessionKey'),
      provider_connection_id: profile.provider_connection_id,
      telephony_sip_profile_id: profile.id,
      target_sip_profile_id: profile.id,
      target_user_id: profile.user_id,
      target_extension: profile.internal_extension,
      operator_internal_extension: profile.internal_extension
    }.compact
  end

  def persist_browser_sip_incoming_metadata!(call_session, profile, params)
    metadata = call_session.metadata.to_h.deep_dup.deep_stringify_keys
    route_metadata = metadata['metadata'].is_a?(Hash) ? metadata['metadata'].deep_dup : {}
    metadata['metadata'] = route_metadata.deep_merge(browser_sip_incoming_metadata(profile, params).deep_stringify_keys)
    call_session.update!(metadata: metadata)
    call_session.reload
  end

  def browser_sip_incoming_payload(call_session, decision, profile)
    route_metadata = browser_sip_incoming_route_metadata(call_session)

    browser_sip_incoming_session_payload(call_session)
      .merge(browser_sip_incoming_operator_payload(route_metadata, profile))
      .merge(route_action: decision[:action] || decision['action'])
      .compact
  end

  def browser_sip_incoming_route_metadata(call_session)
    metadata = call_session.metadata.to_h.deep_stringify_keys
    metadata['metadata'].is_a?(Hash) ? metadata['metadata'] : {}
  end

  def browser_sip_incoming_session_payload(call_session)
    {
      call_sid: call_session.external_call_ref,
      callSid: call_session.external_call_ref,
      call_ref: call_session.external_call_ref,
      provider: call_session.provider,
      status: call_session.status,
      direction: call_session.direction,
      call_direction: call_session.direction,
      inbox_id: call_session.inbox_id,
      inboxId: call_session.inbox_id,
      conversation_id: call_session.conversation&.display_id,
      conversation_display_id: call_session.conversation&.display_id,
      conversation_db_id: call_session.conversation_id,
      contact_id: call_session.contact_id,
      sender_id: call_session.contact_id,
      from_number: call_session.from_number,
      to_number: call_session.to_number
    }
  end

  def browser_sip_incoming_operator_payload(route_metadata, profile)
    {
      operator_candidates: route_metadata['operator_candidates'],
      operator_internal_extension: route_metadata['operator_internal_extension'] || profile.internal_extension,
      sip_profile_id: profile.id,
      sipProfileId: profile.id,
      browser_join_supported: true,
      browserJoinSupported: true
    }
  end

  def browser_sip_incoming_from(params)
    value = params_value(params, 'from_number', 'fromNumber', 'from')
    browser_sip_user_part(value)
  end

  def browser_sip_incoming_to(params, inbox, binding)
    value = params_value(params, 'to_number', 'toNumber', 'to')
    browser_sip_user_part(value).presence || binding.phone_number.presence || inbox.channel&.phone_number
  end

  def browser_sip_user_part(value)
    raw_value = value.to_s.strip
    return if raw_value.blank?

    raw_value[/\A<?sip:([^@;>]+)/i, 1].presence || raw_value
  end

  def params_value(params, *keys)
    keys.each do |key|
      return params[key] if params.key?(key)

      symbol_key = key.to_sym
      return params[symbol_key] if params.key?(symbol_key)
    end

    nil
  end
end
