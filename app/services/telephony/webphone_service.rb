require 'uri'

class Telephony::WebphoneService
  PROVIDER_MANAGED_EXTERNAL_EXTENSION_KINDS = %w[asterisk_analog sipuni binotel].freeze
  PROVIDER_EXTENSION_MODES = %w[external_extension provider_extension].freeze
  JANUS_SIP_WEBPHONE_PROVIDERS = %w[asterisk_analog sipuni binotel].freeze
  JANUS_SIP_PROVIDER_RECORDING_API_PROVIDERS = %w[sipuni].freeze
  JANUS_SIP_BROWSER_RECORDING_FALLBACK_PROVIDERS = %w[asterisk_analog sipuni binotel].freeze
  JANUS_SIP_SERVER_RECORDING_PROVIDERS = %w[asterisk_analog sipuni binotel].freeze
  SIPUNI_PROVIDER_WEBHOOK_CORRELATION_WINDOW = 2.minutes
  BROWSER_SIP_INCOMING_SOURCE = 'browser_janus_sip'.freeze

  def initialize(account:)
    @account = account
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
    return unsupported_webphone_payload(reason: 'ambiguous_sip_profile_presence') if ambiguous_no_inbox_sip_presence?(user, inbox, operator_identity)

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
    call_session = ensure_browser_sip_incoming_call_session!(context, decision)
    call_session = persist_browser_sip_incoming_metadata!(call_session, context, decision)
    call_session = attach_browser_sip_ai_voice!(call_session, decision, context[:profile], params)

    browser_sip_incoming_payload(call_session, decision, context[:profile])
  end

  private

  attr_reader :account

  def webphone_bootstrap_payload_for(user, inbox)
    return if inbox.present?

    native_sessions = janus_sip_webphone_payloads_for(user)
    multi_webphone_payload(native_sessions) if native_sessions.present?
  end

  def webphone_payload_for_identity(_user, inbox, operator_identity)
    return unsupported_provider_extension_payload(inbox, operator_identity) if provider_managed_external_extension?(inbox, operator_identity)
    return janus_sip_webphone_payload(inbox, operator_identity) if janus_sip_webphone?(inbox, operator_identity)

    unsupported_webphone_payload(inbox: inbox, reason: 'janus_sip_profile_required').merge(
      browser_join_supported: false,
      browserJoinSupported: false
    )
  end

  def fallback_provider(inbox, operator_identity)
    inbox_voice_provider(inbox) || operator_identity&.provider
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
      ice_servers: janus_sip_ice_servers,
      iceServers: janus_sip_ice_servers,
      agent_ref: operator_identity.agent_ref,
      agent_aor: operator_identity.agent_aor
    }.merge(janus_sip_recording_contract(provider, profile)).compact
  end

  def janus_sip_recording_contract(provider, profile)
    recording_strategy = janus_sip_recording_strategy(provider, profile)
    recording_fallback_strategy = janus_sip_recording_fallback_strategy(provider, recording_strategy)
    recording_payload = janus_sip_recording_payload(provider, profile, recording_strategy)

    {
      recording_strategy: recording_strategy,
      recordingStrategy: recording_strategy,
      recording_fallback_strategy: recording_fallback_strategy,
      recordingFallbackStrategy: recording_fallback_strategy,
      janus_recording: recording_payload,
      janusRecording: recording_payload
    }
  end

  def janus_sip_recording_strategy(provider, profile)
    provider = provider.to_s
    return 'browser_fallback' if provider.in?(JANUS_SIP_BROWSER_RECORDING_FALLBACK_PROVIDERS)
    return 'janus_server' if provider.in?(JANUS_SIP_SERVER_RECORDING_PROVIDERS) && janus_sip_server_recording_enabled?(provider)
    return 'provider_api' if provider.in?(JANUS_SIP_PROVIDER_RECORDING_API_PROVIDERS) && provider_recording_api_configured?(provider, profile)

    nil
  end

  def janus_sip_recording_fallback_strategy(provider, recording_strategy)
    return unless recording_strategy.in?(%w[janus_server provider_api])
    return 'browser_fallback' if provider.to_s.in?(JANUS_SIP_BROWSER_RECORDING_FALLBACK_PROVIDERS)

    nil
  end

  def janus_sip_recording_payload(provider, profile, recording_strategy)
    return unless recording_strategy == 'janus_server'

    filename_prefix = janus_sip_recording_filename_prefix(provider, profile)
    {
      enabled: true,
      recorder: 'janus_sip',
      audio: true,
      peer_audio: true,
      peerAudio: true,
      filename_prefix: filename_prefix,
      filenamePrefix: filename_prefix,
      fallback_strategy: 'browser_fallback',
      fallbackStrategy: 'browser_fallback',
      recorded_by: 'janus',
      recordedBy: 'janus',
      mode: 'operator',
      layout: 'dual_channel'
    }.merge(janus_sip_recording_destination_payload)
  end

  def janus_sip_recording_destination_payload
    {
      directory: janus_sip_recording_directory,
      recordingDirectory: janus_sip_recording_directory,
      environment: janus_sip_recording_environment
    }
  end

  def provider_recording_api_configured?(provider, profile)
    return false unless provider.to_s == 'sipuni'

    sipuni_webhook_configured?(profile)
  end

  def sipuni_webhook_configured?(profile)
    config = voice_channel_config(profile&.inbox&.channel)
    config[:sipuni_events_webhook_token].present? ||
      config[:sipuni_webhook_token].present? ||
      ENV.fetch('SIPUNI_WEBHOOK_TOKEN', '').presence.present? ||
      ENV.fetch('TELEPHONY_SIPUNI_WEBHOOK_TOKEN', '').presence.present?
  end

  def voice_channel_config(channel)
    return {} if channel.blank?

    config = if channel.respond_to?(:provider_config_hash)
               channel.provider_config_hash
             else
               channel.provider_config
             end
    config.to_h.with_indifferent_access
  end

  def janus_sip_recording_filename_prefix(provider, profile)
    base = ENV.fetch('TELEPHONY_JANUS_RECORDING_FILENAME_PREFIX', 'onelink_janus_sip')
    [base, provider, "account_#{account.id}", "profile_#{profile.id}"]
      .join('_')
      .gsub(/[^a-zA-Z0-9._-]/, '_')
  end

  def janus_sip_recording_directory
    ENV.fetch('TELEPHONY_JANUS_RECORDING_DIR', '/recordings/incoming').presence
  end

  def janus_sip_recording_environment
    ENV.fetch('TELEPHONY_JANUS_RECORDING_ENVIRONMENT', Rails.env).presence
  end

  def janus_sip_server_recording_enabled?(provider)
    provider_key = provider.to_s.upcase
    value = ENV.fetch(
      "TELEPHONY_#{provider_key}_JANUS_SERVER_RECORDING_ENABLED",
      ENV.fetch('TELEPHONY_JANUS_SERVER_RECORDING_ENABLED', 'false')
    )
    ActiveModel::Type::Boolean.new.cast(value)
  end

  def janus_sip_session_payload(profile)
    session_key = janus_sip_session_key(profile)

    {
      session_key: session_key,
      sessionKey: session_key,
      sip_profile_id: profile.id,
      sipProfileId: profile.id,
      account_id: account.id,
      accountId: account.id,
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
      profile&.provider_connection&.provider_kind.presence
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
    dialing = janus_sip_dialing_contract(profile)

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
    }.merge(dialing).compact
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
      sip_proxy: sip[:proxy],
      outboundDialFormat: sip[:outboundDialFormat],
      outbound_dial_format: sip[:outbound_dial_format]
    }.compact
  end

  def janus_sip_dialing_contract(profile)
    outbound_dial_format = janus_sip_dialing_metadata(profile).values_at(
      :outbound_dial_format,
      :outboundDialFormat,
      :dial_format,
      :dialFormat
    ).find(&:present?)
    return {} if outbound_dial_format.blank?

    {
      outbound_dial_format: outbound_dial_format,
      outboundDialFormat: outbound_dial_format
    }
  end

  def janus_sip_dialing_metadata(profile)
    [
      profile&.provider_connection&.metadata,
      profile&.inbox&.telephony_number_binding&.metadata,
      profile&.metadata
    ].each_with_object({}.with_indifferent_access) do |metadata, merged|
      merged.merge!(metadata.to_h.with_indifferent_access)
    end
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

  def janus_sip_ice_servers
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

  def operator_identity_for(user:, inbox:)
    Telephony::OperatorIdentityResolver.new(account: account, inbox: inbox, user: user).resolve
  end

  def ambiguous_no_inbox_sip_presence?(user, inbox, operator_identity)
    return false if inbox.present?
    return false if user.blank?
    return false if operator_identity&.sip_profile.blank?

    account.telephony_sip_profiles
           .where(user_id: user.id, availability_mode: 'browser_webphone', enabled: true)
           .where.not(status: %w[disabled deleting failed])
           .limit(2)
           .count > 1
  end

  def browser_sip_incoming_provider!(inbox)
    provider = inbox_voice_provider(inbox).to_s
    return provider if provider.in?(JANUS_SIP_WEBPHONE_PROVIDERS)

    raise Telephony::Error.new(code: 'UNSUPPORTED_WEBPHONE_PROVIDER', message: 'Inbox does not use native browser SIP',
                               status: :unprocessable_content)
  end

  def browser_sip_incoming_context(provider:, user:, inbox:, params:)
    profile = browser_sip_incoming_profile!(user, inbox, params)
    binding = ensure_voice_number_binding!(inbox)
    {
      provider: provider,
      inbox: inbox,
      params: params,
      profile: profile,
      binding: binding,
      call_ref: browser_sip_incoming_call_ref(provider, profile, binding, params)
    }
  end

  def perform_browser_sip_incoming_route(context)
    Telephony::InboundRoutingService.new(
      payload: browser_sip_incoming_route_payload(context)
    ).perform
  end

  def browser_sip_incoming_profile!(user, inbox, params)
    profile_id = params_value(params, 'sip_profile_id', 'sipProfileId')
    if profile_id.present?
      explicit_profile = browser_sip_incoming_profile_by_id!(profile_id, inbox)
      return explicit_profile if explicit_profile.voice_agent?
    end

    scope = account.telephony_sip_profiles.human_operator.enabled.where(
      user_id: user&.id,
      inbox_id: inbox.id,
      availability_mode: 'browser_webphone'
    ).where.not(status: %w[disabled deleting failed])

    scope = scope.where(id: profile_id) if profile_id.present?

    profile = scope.order(updated_at: :desc, id: :desc).first
    return profile if profile.present?

    raise Telephony::Error.new(code: 'WEBPHONE_SIP_PROFILE_NOT_FOUND', message: 'No browser SIP profile found for this inbox',
                               status: :not_found)
  end

  def browser_sip_incoming_profile_by_id!(profile_id, inbox)
    profile = account.telephony_sip_profiles.enabled.where(
      id: profile_id,
      inbox_id: inbox.id,
      availability_mode: 'browser_webphone'
    ).where.not(status: %w[disabled deleting failed]).first
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

  def browser_sip_incoming_call_ref(provider, profile, binding, params)
    raw_call_ref = params_value(params, 'call_ref', 'callRef', 'call_sid', 'callSid').to_s.strip
    raise Telephony::Error.new(code: 'CALL_REF_REQUIRED', message: 'call_ref is required', status: :unprocessable_content) if raw_call_ref.blank?

    return raw_call_ref if raw_call_ref.start_with?("#{provider}:")

    provider_session = correlated_sipuni_provider_webhook_session(provider, profile, binding, params)
    return provider_session.external_call_ref if provider_session.present?

    "#{provider}:janus:#{profile.id}:#{raw_call_ref}"
  end

  def correlated_sipuni_provider_webhook_session(provider, profile, binding, params)
    return unless provider.to_s == 'sipuni'
    return if profile.blank? || binding.blank?

    from_values, to_values = sipuni_provider_webhook_lookup_values(profile, binding, params)
    return if from_values.blank? || to_values.blank?

    unique_sipuni_provider_webhook_session(profile, binding, from_values, to_values)
  end

  def sipuni_provider_webhook_lookup_values(profile, binding, params)
    [
      browser_sip_phone_lookup_values(browser_sip_incoming_from(params)),
      browser_sip_phone_lookup_values(browser_sip_incoming_to(params, profile.inbox, binding))
    ]
  end

  def unique_sipuni_provider_webhook_session(profile, binding, from_values, to_values)
    sessions = sipuni_provider_webhook_session_scope(profile, binding, from_values, to_values).limit(3).to_a
    sessions.one? ? sessions.first : nil
  end

  def sipuni_provider_webhook_session_scope(profile, binding, from_values, to_values)
    account.telephony_call_sessions
           .active
           .where(provider: 'sipuni', direction: 'inbound', inbox_id: profile.inbox_id, number_binding_id: binding.id)
           .where.not("external_call_ref LIKE 'sipuni:janus:%'")
           .where('COALESCE(started_at, created_at) >= ?', SIPUNI_PROVIDER_WEBHOOK_CORRELATION_WINDOW.ago)
           .where(from_number: from_values, to_number: to_values)
           .order(created_at: :desc, id: :desc)
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
      janus_session_id: params_value(params, 'janus_session_id', 'janusSessionId'),
      janus_handle_id: params_value(params, 'janus_handle_id', 'janusHandleId'),
      janus_unique_id: params_value(params, 'janus_unique_id', 'janusUniqueId'),
      janus_master_id: params_value(params, 'janus_master_id', 'janusMasterId'),
      provider_connection_id: profile.provider_connection_id,
      telephony_sip_profile_id: profile.id,
      telephony_sip_profile_kind: profile.profile_kind,
      voice_agent_sip_profile_id: profile.voice_agent? ? profile.id : nil,
      target_sip_profile_id: profile.id,
      target_user_id: profile.user_id,
      target_extension: profile.internal_extension,
      voice_agent: profile.voice_agent?,
      operator_internal_extension: profile.internal_extension
    }.compact
  end

  def persist_browser_sip_incoming_metadata!(call_session, context, decision)
    metadata = call_session.metadata.to_h.deep_dup.deep_stringify_keys
    route_metadata = metadata['metadata'].is_a?(Hash) ? metadata['metadata'].deep_dup : {}
    metadata['metadata'] = route_metadata.deep_merge(browser_sip_incoming_route_metadata_payload(context, decision))
    call_session.update!(metadata: metadata)
    call_session.reload
  end

  def ensure_browser_sip_incoming_call_session!(context, decision)
    existing = account.telephony_call_sessions.find_by(external_call_ref: context[:call_ref])
    return existing if existing.present?

    conversation = browser_sip_incoming_decision_conversation(decision)
    binding = context.fetch(:binding)
    params = context.fetch(:params)
    account.telephony_call_sessions.create!(
      external_call_ref: context.fetch(:call_ref),
      account: account,
      inbox: context.fetch(:inbox),
      number_binding: binding,
      provider: context.fetch(:provider),
      status: 'ringing',
      direction: 'inbound',
      from_number: browser_sip_incoming_from(params),
      to_number: browser_sip_incoming_to(params, context.fetch(:inbox), binding),
      started_at: Time.current,
      last_event_at: Time.current,
      conversation: conversation,
      contact: conversation&.contact,
      metadata: browser_sip_incoming_initial_metadata(context, decision)
    )
  rescue ActiveRecord::RecordInvalid => e
    raise unless e.record&.errors&.of_kind?(:external_call_ref, :taken)

    account.telephony_call_sessions.find_by!(external_call_ref: context[:call_ref])
  end

  def browser_sip_incoming_decision_conversation(decision)
    conversation_id = decision[:conversation_id] || decision['conversation_id']
    return if conversation_id.blank?

    account.conversations.find_by(id: conversation_id)
  end

  def browser_sip_incoming_initial_metadata(context, decision)
    { 'metadata' => browser_sip_incoming_route_metadata_payload(context, decision) }
  end

  def browser_sip_incoming_route_metadata_payload(context, decision)
    browser_sip_incoming_metadata(context.fetch(:profile), context.fetch(:params)).deep_stringify_keys.merge(
      'route_action' => decision[:action] || decision['action'],
      'route_reason' => decision[:reason] || decision['reason'],
      'chatwoot_conversation_id' => decision[:conversation_id] || decision['conversation_id'],
      'chatwoot_conversation_status' => decision[:conversation_status] || decision['conversation_status'],
      'number_ref' => context.fetch(:binding).number_ref
    ).compact
  end

  def attach_browser_sip_ai_voice!(call_session, decision, profile, params)
    Telephony::AiVoice::JanusSipAttachService.new(
      call_session: call_session,
      routing_decision: decision,
      sip_profile: profile,
      params: params
    ).perform
    call_session.reload
  end

  def browser_sip_incoming_payload(call_session, decision, profile)
    route_metadata = browser_sip_incoming_route_metadata(call_session)

    browser_sip_incoming_session_payload(call_session, route_metadata)
      .merge(browser_sip_incoming_operator_payload(route_metadata, profile))
      .merge(route_action: decision[:action] || decision['action'])
      .merge(browser_sip_incoming_ai_voice_payload(call_session))
      .compact
  end

  def browser_sip_incoming_route_metadata(call_session)
    metadata = call_session.metadata.to_h.deep_stringify_keys
    metadata['metadata'].is_a?(Hash) ? metadata['metadata'] : {}
  end

  def browser_sip_incoming_session_payload(call_session, route_metadata = {})
    sip_profile_id = route_metadata['telephony_sip_profile_id'] || route_metadata['target_sip_profile_id']

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
      to_number: call_session.to_number,
      sip_profile_id: sip_profile_id,
      sipProfileId: sip_profile_id,
      janus_call_ref: route_metadata['janus_call_ref'],
      janusCallRef: route_metadata['janus_call_ref'],
      janus_session_key: route_metadata['janus_session_key'],
      janusSessionKey: route_metadata['janus_session_key'],
      janus_session_id: route_metadata['janus_session_id'],
      janusSessionId: route_metadata['janus_session_id'],
      janus_handle_id: route_metadata['janus_handle_id'],
      janusHandleId: route_metadata['janus_handle_id'],
      janus_unique_id: route_metadata['janus_unique_id'],
      janusUniqueId: route_metadata['janus_unique_id'],
      janus_master_id: route_metadata['janus_master_id'],
      janusMasterId: route_metadata['janus_master_id'],
      sipuni_native_webphone_correlation: route_metadata['sipuni_native_webphone_correlation'],
      sipuniNativeWebphoneCorrelation: route_metadata['sipuni_native_webphone_correlation']
    }
  end

  def browser_sip_incoming_ai_voice_payload(call_session)
    ai_voice = call_session.metadata.to_h.deep_stringify_keys['ai_voice']
    return {} unless ai_voice.is_a?(Hash)

    {
      ai_voice: ai_voice,
      aiVoice: ai_voice
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

  def browser_sip_phone_lookup_values(value)
    raw_value = value.to_s.strip
    normalized = Contacts::PhoneNumberNormalizer.normalize(raw_value) ||
                 Contacts::PhoneNumberNormalizer.normalize(raw_value, default_country: 'KZ')

    [
      raw_value,
      normalized,
      normalized&.delete_prefix('+'),
      raw_value.delete_prefix('+')
    ].compact_blank.uniq
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
