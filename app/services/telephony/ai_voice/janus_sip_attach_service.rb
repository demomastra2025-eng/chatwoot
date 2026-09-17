class Telephony::AiVoice::JanusSipAttachService
  SUPPORTED_PROVIDERS = %w[asterisk_analog sipuni binotel beeline wazo].freeze

  pattr_initialize [:call_session!, :routing_decision!, :sip_profile!, :params!, { runtime_client: nil }]

  def perform
    return skip!('not_ai_route') unless ai_route?
    return skip!('unsupported_provider') unless supported_provider?
    return skip!('sip_profile_not_voice_agent') unless voice_agent_sip_profile?
    return skip!('runtime_disabled') unless runtime_client_instance.enabled?

    response = runtime_client_instance.attach_call(runtime_payload)
    mark_attached!(response)
    response
  rescue Telephony::AiVoice::JanusSipRuntimeClient::ConnectionError,
         Telephony::AiVoice::JanusSipRuntimeClient::AttachError => e
    mark_failed!(e)
    nil
  end

  private

  def ai_route?
    decision_value('action') == 'ai'
  end

  def supported_provider?
    provider.in?(SUPPORTED_PROVIDERS)
  end

  def voice_agent_sip_profile?
    sip_profile&.voice_agent?
  end

  def runtime_client_instance
    @runtime_client_instance ||= runtime_client || Telephony::AiVoice::JanusSipRuntimeClient.new
  end

  def provider
    @provider ||= call_session.provider.to_s
  end

  def runtime_payload
    {
      call_ref: call_session.external_call_ref,
      bridge_call_ref: runtime_bridge_call_ref,
      account_id: call_session.account_id,
      inbox_id: call_session.inbox_id,
      conversation_id: call_session.conversation_id,
      call_session_id: call_session.id,
      number_binding_id: call_session.number_binding_id,
      number_ref: call_session.number_binding&.number_ref,
      provider: provider,
      direction: call_session.direction || 'inbound',
      caller_number: call_session.from_number,
      ingress_number: call_session.to_number,
      transport: 'janus_sip',
      sip_profile_id: sip_profile.id,
      sip_profile: sip_profile_payload,
      janus: janus_payload,
      ai_context: ai_context_payload,
      routing: routing_payload
    }.compact
  end

  def janus_payload
    {
      plugin: 'janus.plugin.sip',
      call_ref: param_value('call_ref', 'callRef', 'call_sid', 'callSid'),
      session_key: param_value('session_key', 'sessionKey'),
      session_id: param_value('janus_session_id', 'janusSessionId'),
      handle_id: param_value('janus_handle_id', 'janusHandleId'),
      unique_id: param_value('janus_unique_id', 'janusUniqueId'),
      master_id: param_value('janus_master_id', 'janusMasterId'),
      browser_bridge: browser_bridge_payload,
      rtp_bridge: rtp_bridge_payload,
      rtp_forward: rtp_forward_payload
    }.compact
  end

  def sip_profile_payload
    {
      id: sip_profile.id,
      profile_kind: sip_profile.profile_kind,
      voice_agent: sip_profile.voice_agent?,
      internal_extension: sip_profile.internal_extension,
      sip_username: sip_profile.sip_username,
      agent_aor: sip_profile.agent_aor,
      credentials_ref: sip_profile.credentials_ref,
      sip_password_configured: sip_profile.sip_password_configured?
    }.compact
  end

  def routing_payload
    {
      action: decision_value('action'),
      reason: decision_value('reason'),
      conversation_status: decision_value('conversation_status'),
      captain_assistant_id: routing_policy&.captain_assistant_id,
      ai_mode: decision_value('ai_mode'),
      app_ref: decision_value('app_ref'),
      ai_context: ai_context_payload
    }.compact
  end

  def ai_context_payload
    decision_value('ai_context') || decision_value('aiContext')
  end

  def runtime_bridge_call_ref
    return call_session.external_call_ref if call_session.external_call_ref.present?

    decision_value('bridge_call_ref')
  end

  def rtp_bridge_payload
    return unless env_enabled?('VOICE_AGENT_JANUS_RTP_BRIDGE_ENABLED', 'ONELINK_AI_VOICE_JANUS_RTP_BRIDGE_ENABLED')

    {
      enabled: true,
      input_codec: env_value('VOICE_AGENT_JANUS_RTP_BRIDGE_INPUT_CODEC', 'ONELINK_AI_VOICE_JANUS_RTP_BRIDGE_INPUT_CODEC') || 'pcmu',
      output: {
        host: env_value('VOICE_AGENT_JANUS_RTP_BRIDGE_OUTPUT_HOST', 'ONELINK_AI_VOICE_JANUS_RTP_BRIDGE_OUTPUT_HOST'),
        port: env_integer('VOICE_AGENT_JANUS_RTP_BRIDGE_OUTPUT_PORT', 'ONELINK_AI_VOICE_JANUS_RTP_BRIDGE_OUTPUT_PORT')
      }.compact
    }
  end

  def browser_bridge_payload
    return unless env_enabled?('VOICE_AGENT_JANUS_BROWSER_BRIDGE_ENABLED', 'ONELINK_AI_VOICE_JANUS_BROWSER_BRIDGE_ENABLED')

    { enabled: true }
  end

  def rtp_forward_payload
    return unless env_enabled?('VOICE_AGENT_JANUS_RTP_FORWARD_ENABLED', 'ONELINK_AI_VOICE_JANUS_RTP_FORWARD_ENABLED')

    {
      enabled: true,
      stream: {
        host: env_value('VOICE_AGENT_JANUS_RTP_FORWARD_HOST', 'ONELINK_AI_VOICE_JANUS_RTP_FORWARD_HOST'),
        host_family: env_value('VOICE_AGENT_JANUS_RTP_FORWARD_HOST_FAMILY', 'ONELINK_AI_VOICE_JANUS_RTP_FORWARD_HOST_FAMILY') || 'ipv4',
        payload_type: env_integer('VOICE_AGENT_JANUS_RTP_FORWARD_PAYLOAD_TYPE', 'ONELINK_AI_VOICE_JANUS_RTP_FORWARD_PAYLOAD_TYPE')
      }.compact
    }
  end

  def mark_attached!(response)
    update_ai_voice_metadata!(
      'state' => 'attached',
      'transport' => 'janus_sip',
      'provider' => provider,
      'runtime_response' => response.to_h.slice('status', 'mode', 'call_ref', 'transport', 'browser_bridge'),
      'updated_at' => Time.current.iso8601
    )
  end

  def mark_failed!(error)
    update_ai_voice_metadata!(
      'state' => 'attach_failed',
      'transport' => 'janus_sip',
      'provider' => provider,
      'error_class' => error.class.name,
      'error_message' => error.message.to_s.truncate(300),
      'http_status' => error.respond_to?(:http_status) ? error.http_status : nil,
      'updated_at' => Time.current.iso8601
    )
  end

  def skip!(reason)
    if ai_route?
      update_ai_voice_metadata!(
        'state' => 'skipped',
        'transport' => 'janus_sip',
        'provider' => provider,
        'reason' => reason,
        'updated_at' => Time.current.iso8601
      )
    end
    nil
  end

  def update_ai_voice_metadata!(attrs)
    metadata = call_session.metadata.to_h.deep_dup.deep_stringify_keys
    metadata['ai_voice'] = metadata.fetch('ai_voice', {}).merge(attrs.compact)
    call_session.update!(metadata: metadata)
    call_session.reload
  end

  def routing_policy
    @routing_policy ||= call_session.number_binding&.routing_policy
  end

  def decision_value(key)
    routing_decision[key.to_sym] || routing_decision[key.to_s]
  end

  def param_value(*keys)
    keys.each do |key|
      return params[key] if params.key?(key)

      symbol_key = key.to_sym
      return params[symbol_key] if params.key?(symbol_key)
    end

    nil
  end

  def env_enabled?(*keys)
    ActiveModel::Type::Boolean.new.cast(env_value(*keys))
  end

  def env_value(*keys)
    keys.each do |key|
      value = ENV.fetch(key, nil).presence
      return value if value.present?
    end

    nil
  end

  def env_integer(*keys)
    value = env_value(*keys)
    return if value.blank?

    Integer(value, exception: false)
  end
end
